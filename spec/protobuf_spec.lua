-- distilled.protobuf: replays the differential vectors Distilled's core protobuf.ts
-- produced (spec/golden/protobuf/vectors.json, written by verify/lib/protobuf_vectors.mjs:
-- seeded random proto3 JSON values over every field kind, invalid values, mutated and
-- hand-written byte strings, gRPC and gRPC-Web frames), plus unit cases for the parts a
-- vector cannot show (IEEE-754 corners, 64-bit edges, depth limits).
local t = require("spec.harness")
local json = require("distilled.json")
local pb = require("distilled.protobuf")

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function hex(s)
  return (string.gsub(s, ".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function unhex(h)
  return (string.gsub(h, "%x%x", function(x)
    return string.char(tonumber(x, 16))
  end))
end

local vectors
local function golden()
  if not vectors then
    vectors = assert(json.decode(read_file(t.root .. "/spec/golden/protobuf/vectors.json")))
  end
  return vectors
end

-- the same JSON text for the same value, whatever the runtime's number subtypes
local function canon(v)
  return assert(json.encode(v))
end

t.describe("protobuf differential vectors (protobuf.ts)", function()
  t.it("encodes every value to protobuf.ts's bytes, or fails with its message", function()
    local v = golden()
    local d = v.descriptors
    t.truthy(#v.encode > 200)
    local ok_count, err_count = 0, 0
    for i, c in ipairs(v.encode) do
      local value = json.decode(c.value)
      if c.value == "null" then
        value = json.null
      end
      local bytes, err = pb.encode(d, c.msg, value)
      local label = i .. ": " .. c.value
      if c.error then
        t.eq(bytes, nil, label)
        t.eq(err and err.message, c.error, label)
        t.eq(err and err.tag, "InvalidInput", label)
        err_count = err_count + 1
      else
        t.eq(err and err.message, nil, label)
        t.eq(hex(bytes), c.hex, label)
        local back, derr = pb.decode(d, c.msg, bytes, { nonfinite = "null" })
        t.eq(derr and derr.message, nil, label)
        t.eq(canon(back), canon(json.decode(c.decoded)), label)
        ok_count = ok_count + 1
      end
    end
    t.truthy(ok_count > 100)
    t.truthy(err_count > 50)
  end)

  t.it("decodes every byte string to protobuf.ts's value, or fails with its message", function()
    local v = golden()
    local d = v.descriptors
    t.truthy(#v.decode > 200)
    for i, c in ipairs(v.decode) do
      local value, err = pb.decode(d, c.msg, unhex(c.hex), { nonfinite = "null" })
      local label = i .. ": " .. c.hex
      if c.error then
        t.eq(value, nil, label)
        t.eq(err and err.message, c.error, label)
        t.eq(err and err.protobuf, c.error_tag, label)
      else
        t.eq(err and err.message, nil, label)
        t.eq(canon(value), canon(json.decode(c.json)), label)
      end
    end
  end)

  t.it("splits gRPC and gRPC-Web bodies into frames as FrameReader does", function()
    for i, c in ipairs(golden().frames) do
      local r, err = pb.unframe(unhex(c.hex))
      if c.error then
        t.eq(r, nil, i)
        t.eq(err and err.message, c.error, i)
      else
        local got = {}
        for j, m in ipairs(r.messages) do
          got[j] = hex(m)
        end
        t.same(got, c.messages, i)
        t.same(r.trailers, c.trailers, i)
        t.eq(r.rest, c.rest, i)
      end
    end
  end)
end)

local D = {
  messages = {
    ["t.M"] = {
      { 1, "i64", "int64" },
      { 2, "u64", "uint64" },
      { 3, "s64", "sint64" },
      { 4, "f64", "fixed64" },
      { 5, "sf64", "sfixed64" },
      { 6, "d", "double" },
      { 7, "f", "float" },
      { 8, "child", "message", "t.M" },
      { 9, "st", "message", "google.protobuf.Struct" },
      { 10, "s", "string" },
      { 11, "list", "int32", 0, 1 },
    },
  },
  enums = {},
  methods = {},
}

local function roundtrip(field, value)
  local bytes, err = pb.encode(D, "t.M", { [field] = value })
  t.eq(err, nil)
  local back = assert(pb.decode(D, "t.M", bytes))
  return back[field], bytes
end

t.describe("protobuf 64-bit integers", function()
  t.it("round-trips the extremes of every 64-bit kind as decimal strings", function()
    for _, c in ipairs({
      { "i64", "-9223372036854775808" },
      { "i64", "9223372036854775807" },
      { "i64", "-1" },
      { "u64", "18446744073709551615" },
      { "u64", "9007199254740993" },
      { "s64", "-9223372036854775808" },
      { "s64", "9223372036854775807" },
      { "s64", "-4294967297" },
      { "f64", "18446744073709551615" },
      { "sf64", "-9223372036854775808" },
      { "sf64", "-2" },
    }) do
      t.eq(roundtrip(c[1], c[2]), c[2], c[1] .. " " .. c[2])
    end
  end)

  t.it("accepts numbers and JSON number text, and rejects the rest", function()
    t.eq(roundtrip("i64", 42), "42")
    t.eq(roundtrip("i64", "1e5"), "100000")
    t.eq(roundtrip("i64", -2 ^ 53), "-9007199254740992")
    local _, err = pb.encode(D, "t.M", { u64 = "18446744073709551616" })
    t.eq(err.message, "t.M.u64: 18446744073709551616 is out of range for uint64")
    _, err = pb.encode(D, "t.M", { i64 = 1.5 })
    t.eq(err.message, "t.M.i64: expected an integer, got 1.5")
    t.eq(err.member, "t.M")
  end)

  t.it("writes the ten-byte varint for -1 and zigzag for sint64", function()
    local _, bytes = roundtrip("i64", "-1")
    t.eq(hex(bytes), "08ffffffffffffffffff01")
    _, bytes = roundtrip("s64", "-1")
    t.eq(hex(bytes), "1801")
    _, bytes = roundtrip("s64", "1")
    t.eq(hex(bytes), "1802")
  end)
end)

t.describe("protobuf IEEE-754", function()
  t.it("packs doubles bit for bit, specials and subnormals included", function()
    local cases = {
      { 1, "000000000000f03f" },
      { -2, "00000000000000c0" },
      { 0.1, "9a9999999999b93f" },
      { 5e-324, "0100000000000000" },
      { 2.2250738585072014e-308, "0000000000001000" },
      { 1.7976931348623157e308, "ffffffffffffef7f" },
      { 1 / 0, "000000000000f07f" },
      { -1 / 0, "000000000000f0ff" },
    }
    for _, c in ipairs(cases) do
      t.eq(hex(pb._pack_double(c[1])), c[2], tostring(c[1]))
      t.eq(pb._unpack_double(unhex(c[2]), 1), c[1], c[2])
    end
    local nan = pb._unpack_double(pb._pack_double(0 / 0), 1)
    t.truthy(nan ~= nan)
    local negzero = pb._unpack_double(unhex("0000000000000080"), 1)
    t.eq(1 / negzero, -1 / 0)
  end)

  t.it("rounds floats to nearest even, like DataView.setFloat32", function()
    local cases = {
      { 1, "0000803f" },
      { 0.1, "cdcccc3d" },
      { 16777217, "0000804b" }, -- tie: rounds to even (16777216)
      { 16777219, "0200804b" }, -- tie: rounds to even (16777220)
      { 1.401298464324817e-45, "01000000" },
      { 7e-46, "00000000" }, -- below half the smallest subnormal
      { 1.1754942106924411e-38, "ffff7f00" },
      { 3.4028234663852886e38, "ffff7f7f" },
    }
    for _, c in ipairs(cases) do
      t.eq(hex(pb._pack_float(c[1])), c[2], tostring(c[1]))
    end
    t.eq(pb._unpack_float(unhex("cdcccc3d"), 1), 0.10000000149011612)
  end)
end)

t.describe("protobuf limits and misuse", function()
  t.it("refuses nesting deeper than MAX_DEPTH instead of overflowing the stack", function()
    local value = {}
    local cur = value
    for _ = 1, pb.MAX_DEPTH + 5 do
      cur.child = {}
      cur = cur.child
    end
    local bytes, err = pb.encode(D, "t.M", value)
    t.eq(bytes, nil)
    t.match(err.message, "nesting deeper than 100 levels")
    -- 99 levels encode and decode
    value = {}
    cur = value
    for _ = 1, 98 do
      cur.child = {}
      cur = cur.child
    end
    bytes = assert(pb.encode(D, "t.M", value))
    t.truthy(pb.decode(D, "t.M", bytes))
    -- decoding: 105 nested child messages, built by hand
    local function uvarint(n)
      local out = ""
      while n > 127 do
        out = out .. string.char(n % 128 + 128)
        n = math.floor(n / 128)
      end
      return out .. string.char(n)
    end
    local deep = ""
    for _ = 1, pb.MAX_DEPTH + 5 do
      deep = "\66" .. uvarint(#deep) .. deep
    end
    local v, derr = pb.decode(D, "t.M", deep)
    t.eq(v, nil)
    t.eq(derr.message, "nesting deeper than 100 levels")
  end)

  t.it("catches a cyclic value through the depth limit", function()
    local v = {}
    v.child = v
    local bytes, err = pb.encode(D, "t.M", v)
    t.eq(bytes, nil)
    t.eq(err.tag, "InvalidInput")
  end)

  t.it("replaces invalid UTF-8 with U+FFFD both ways", function()
    t.eq(pb.utf8_fix("a\255b"), "a\239\191\189b")
    t.eq(pb.utf8_fix("\226\130"), "\239\191\189")
    t.eq(pb.utf8_fix("ok é"), "ok é")
    local back = roundtrip("s", "x\192y")
    t.eq(back, "x\239\191\189y")
  end)

  t.it("decodes NaN as json.null only when asked", function()
    local bytes = assert(pb.encode(D, "t.M", { d = "NaN" }))
    local v = assert(pb.decode(D, "t.M", bytes))
    t.truthy(v.d ~= v.d)
    v = assert(pb.decode(D, "t.M", bytes, { nonfinite = "null" }))
    t.eq(v.d, json.null)
  end)

  t.it("raises for misuse, never for bad data", function()
    t.raises(function()
      pb.encode(nil, "t.M", {})
    end, "descriptors")
    t.raises(function()
      pb.decode(D, "t.M", 5)
    end, "byte string")
    local v, err = pb.decode(D, "t.M", "\255\255\255")
    t.eq(v, nil)
    t.eq(err.tag, "ParseError")
  end)

  t.it("encodes a long repeated field and a large Struct (no concat limit)", function()
    local list = {}
    for i = 1, 5000 do
      list[i] = i
    end
    local back = roundtrip("list", json.array(list))
    t.eq(#back, 5000)
    t.eq(back[5000], 5000)
    local st = {}
    for i = 1, 3000 do
      st["k" .. i] = i
    end
    back = roundtrip("st", st)
    t.eq(back.k3000, 3000)
  end)
end)
