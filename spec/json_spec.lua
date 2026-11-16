local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")

local function decode_ok(text)
  local v, err = json.decode(text)
  if err then
    t.fail("decode failed: " .. tostring(err))
  end
  return v
end

local function encode_ok(v, opts)
  local s, err = json.encode(v, opts)
  if err then
    t.fail("encode failed: " .. tostring(err))
  end
  return s
end

local NEG_INF = -1 / 0
local INF = 1 / 0

t.describe("json.decode literals and null", function()
  t.it("decodes true, false and null", function()
    t.eq(decode_ok("true"), true)
    t.eq(decode_ok("false"), false)
    t.eq(decode_ok("null"), json.null)
  end)

  t.it("json.null prints as null and is read-only", function()
    t.eq(tostring(json.null), "null")
    t.raises(function()
      json.null.x = 1
    end, "read%-only")
  end)

  t.it("keeps null inside arrays, so the length counts it", function()
    local v = decode_ok("[1,null,3]")
    t.eq(#v, 3)
    t.eq(v[2], json.null)
    t.eq(encode_ok(v), "[1,null,3]")
  end)

  t.it("keeps null members of objects present", function()
    local v = decode_ok('{"a":null,"b":1}')
    t.eq(rawget(v, "a"), json.null)
    t.eq(v.c, nil)
    t.eq(encode_ok(v), '{"a":null,"b":1}')
  end)

  t.it("a trailing null in an array survives", function()
    local v = decode_ok("[null,null]")
    t.eq(#v, 2)
    t.eq(encode_ok(v), "[null,null]")
  end)
end)

t.describe("json empty array vs empty object", function()
  t.it("decodes [] as a marked array and {} as an unmarked table", function()
    local a, o = decode_ok("[]"), decode_ok("{}")
    t.truthy(json.is_array(a))
    t.falsy(json.is_array(o))
    t.eq(next(a), nil)
    t.eq(next(o), nil)
  end)

  t.it("round-trips both", function()
    t.eq(encode_ok(decode_ok("[]")), "[]")
    t.eq(encode_ok(decode_ok("{}")), "{}")
    t.eq(encode_ok(decode_ok('{"a":[],"b":{},"c":[[],{}]}')), '{"a":[],"b":{},"c":[[],{}]}')
  end)

  t.it("an unmarked empty table encodes as an object", function()
    t.eq(encode_ok({}), "{}")
  end)

  t.it("json.array and json.object marks win", function()
    t.eq(encode_ok(json.array({})), "[]")
    t.eq(encode_ok(json.object({})), "{}")
    t.eq(encode_ok(json.object({ "x", "y" })), '{"1":"x","2":"y"}')
    t.truthy(json.is_object(json.object({})))
  end)

  t.it("marking returns the same table", function()
    local x = {}
    t.eq(json.array(x), x)
    t.truthy(json.is_array(x))
  end)

  t.it("marks a table that already has a metatable without replacing it", function()
    local mt = { __index = function()
      return "dflt"
    end }
    local x = setmetatable({}, mt)
    json.array(x)
    t.eq(getmetatable(x), mt)
    t.truthy(json.is_array(x))
    t.eq(encode_ok(x), "[]")
  end)

  t.it("rejects marking a non-table", function()
    t.raises(function()
      json.array("x")
    end, "expected a table")
  end)
end)

t.describe("json strings", function()
  t.it("decodes every escape", function()
    t.eq(decode_ok([["\" \\ \/ \b \f \n \r \t"]]), '" \\ / \b \f \n \r \t')
  end)

  t.it("decodes \\u escapes to UTF-8 at each length boundary", function()
    t.eq(decode_ok([["\u0041"]]), "A")
    t.eq(decode_ok([["\u0000"]]), "\0")
    t.eq(decode_ok([["\u007f"]]), "\127")
    t.eq(decode_ok([["\u0080"]]), "\194\128")
    t.eq(decode_ok([["\u07FF"]]), "\223\191")
    t.eq(decode_ok([["\u0800"]]), "\224\160\128")
    t.eq(decode_ok([["\uffff"]]), "\239\191\191")
    t.eq(decode_ok([["\u00e9"]]), "é")
  end)

  t.it("decodes surrogate pairs, upper and lower case", function()
    t.eq(decode_ok([["\ud83d\ude00"]]), "\240\159\152\128")
    t.eq(decode_ok([["\uD83D\uDE00"]]), "\240\159\152\128")
    t.eq(decode_ok([["\ud800\udc00"]]), "\240\144\128\128") -- U+10000
    t.eq(decode_ok([["\udbff\udfff"]]), "\244\143\191\191") -- U+10FFFF
  end)

  t.it("turns lone surrogates into U+FFFD", function()
    local fffd = "\239\191\189"
    t.eq(decode_ok([["\ud83d"]]), fffd)
    t.eq(decode_ok([["\ude00x"]]), fffd .. "x")
    t.eq(decode_ok([["\ud83d\u0041"]]), fffd .. "A")
  end)

  t.it("passes raw UTF-8 through both ways", function()
    t.eq(decode_ok('"héllo 😀 中"'), "héllo 😀 中")
    t.eq(encode_ok("héllo 😀 中"), '"héllo 😀 中"')
  end)

  t.it("encodes control characters, quote and backslash like JSON.stringify", function()
    t.eq(encode_ok('a"b\\c'), [["a\"b\\c"]])
    t.eq(encode_ok("\b\f\n\r\t"), [["\b\f\n\r\t"]])
    t.eq(encode_ok("\0\1\31"), [["\u0000\u0001\u001f"]])
    t.eq(encode_ok("\127/"), '"\127/"') -- DEL and / are not escaped
  end)

  t.it("round-trips every byte value below 0x80", function()
    local chars = {}
    for b = 0, 127 do
      chars[#chars + 1] = string.char(b)
    end
    local s = table.concat(chars)
    t.eq(decode_ok(encode_ok(s)), s)
  end)

  t.it("handles strings with thousands of escapes (gopher-lua concat limit)", function()
    local s = string.rep('a"\n', 6000)
    local text = encode_ok(s)
    t.eq(decode_ok(text), s)
  end)
end)

t.describe("json numbers", function()
  t.it("decodes integers, negatives, fractions and exponents", function()
    t.eq(decode_ok("0"), 0)
    t.eq(decode_ok("42"), 42)
    t.eq(decode_ok("-17"), -17)
    t.eq(decode_ok("3.25"), 3.25)
    t.eq(decode_ok("-0.5"), -0.5)
    t.eq(decode_ok("1E5"), 100000)
    t.eq(decode_ok("1e+5"), 100000)
    t.eq(decode_ok("2.5e-3"), 0.0025)
    t.eq(decode_ok("1.7976931348623157e308"), 1.7976931348623157e308)
    t.eq(decode_ok("5e-324"), 5e-324)
  end)

  t.it("decodes integers up to 2^53 exactly", function()
    t.eq(decode_ok("9007199254740992"), 2 ^ 53)
    t.eq(decode_ok("-9007199254740992"), -(2 ^ 53))
    t.eq(decode_ok("9007199254740991"), 2 ^ 53 - 1)
    t.eq(decode_ok("123456789012345"), 123456789012345)
  end)

  t.it("decodes -0 as negative zero", function()
    t.eq(1 / decode_ok("-0"), NEG_INF)
    t.eq(1 / decode_ok("-0.0"), NEG_INF)
    t.eq(1 / decode_ok("0"), INF)
  end)

  t.it("decodes out-of-range numbers to infinity and zero", function()
    t.eq(decode_ok("1e400"), INF)
    t.eq(decode_ok("-1e400"), NEG_INF)
    t.eq(decode_ok("1e-400"), 0)
    t.eq(decode_ok("123456789012345678901234567890"), 1.2345678901234568e29)
  end)

  t.it("decoded whole numbers print without a fraction on every runtime", function()
    t.eq(tostring(decode_ok("10")), "10")
    t.eq(tostring(decode_ok("1.0")), "1")
    t.eq(tostring(decode_ok("1e3")), "1000")
  end)

  t.it("encodes whole numbers without fraction or exponent up to 2^53", function()
    t.eq(encode_ok(0), "0")
    t.eq(encode_ok(100), "100")
    t.eq(encode_ok(-42), "-42")
    t.eq(encode_ok(1e15), "1000000000000000")
    t.eq(encode_ok(2 ^ 53), "9007199254740992")
    t.eq(encode_ok(-(2 ^ 53)), "-9007199254740992")
    t.eq(encode_ok(1e16), "10000000000000000")
  end)

  t.it("encodes like JSON.stringify (shortest round-trip digits)", function()
    t.eq(encode_ok(0.1), "0.1")
    t.eq(encode_ok(1 / 3), "0.3333333333333333")
    t.eq(encode_ok(-1.5), "-1.5")
    t.eq(encode_ok(1e21), "1e+21")
    t.eq(encode_ok(1e20), "100000000000000000000")
    t.eq(encode_ok(1e-7), "1e-7")
    t.eq(encode_ok(1e-6), "0.000001")
    t.eq(encode_ok(1.5e-10), "1.5e-10")
    t.eq(encode_ok(1e300), "1e+300")
    t.eq(encode_ok(5e-324), "5e-324")
    t.eq(encode_ok(2 ^ 60), "1152921504606847000")
    t.eq(encode_ok(1.7976931348623157e308), "1.7976931348623157e+308")
  end)

  t.it("encodes -0 as 0, like JSON.stringify", function()
    local z = 0
    t.eq(encode_ok(-z * 1.0), "0")
    t.eq(encode_ok(decode_ok("-0")), "0")
  end)

  t.it("refuses NaN and infinities", function()
    local e = t.err(json.encode(0 / 0))
    t.eq(e.tag, "InvalidInput")
    t.match(e.message, "NaN")
    t.match(t.err(json.encode({ a = INF })).message, "infinite")
    t.match(t.err(json.encode({ NEG_INF })).message, "infinite")
  end)
end)

t.describe("json invalid input", function()
  local cases = {
    { "", 1, "end of input" },
    { "   ", 4, "end of input" },
    { "[1,]", 4, "']'" },
    { '{"a":1,}', 8, "string key" },
    { "[1 2]", 4, "',' or ']'" },
    { '{"a" 1}', 6, "':'" },
    { '{"a":1 "b":2}', 8, "',' or '}'" },
    { "{a:1}", 2, "string key" },
    { "tru", 1, "'t'" },
    { "nul", 1, "'n'" },
    { "True", 1, "'T'" },
    { "undefined", 1, "'u'" },
    { "NaN", 1, "'N'" },
    { "'x'", 1, "'''" },
    { '"abc', 1, "unterminated" },
    { '"abc\\', 1, "unterminated" },
    { '"a\nb"', 3, "control character 0x0a" },
    { '"a\tb"', 3, "control character 0x09" },
    { '"a\0b"', 3, "control character 0x00" },
    { '"\\x"', 2, "invalid escape" },
    { '"\\u12G4"', 2, "invalid \\u escape" },
    { '"\\u12"', 2, "invalid \\u escape" },
    { "[1] x", 5, "trailing garbage" },
    { "{} {}", 4, "trailing garbage" },
    { "1 2", 3, "trailing garbage" },
    { "01", 1, "leading zero" },
    { "-01", 2, "leading zero" },
    { "-", 2, "invalid number" },
    { "+1", 1, "'+'" },
    { "1.", 3, "digit after" },
    { ".5", 1, "'.'" },
    { "1e", 3, "exponent" },
    { "1e+", 3, "exponent" },
    { "0x10", 2, "trailing garbage" },
    { "[", 2, "end of input" },
    { '{"a":', 6, "end of input" },
    { "]", 1, "']'" },
    { "\239\187\191{}", 1, "0xef" }, -- a BOM is not whitespace (JSON.parse agrees)
  }
  for _, case in ipairs(cases) do
    t.it(string.format("rejects %q at position %d", case[1], case[2]), function()
      local e = t.fails_with("ParseError", json.decode(case[1]))
      t.eq(e.position, case[2], "position")
      t.match(e.message, "position " .. case[2], true)
      t.match(e.message, case[3], true)
    end)
  end

  t.it("names line and column", function()
    local e = t.err(json.decode('{\n  "a": 1,\n  "b": x\n}'))
    t.match(e.message, "line 3, column 8", true)
  end)

  t.it("raises for a non-string argument (misuse)", function()
    t.raises(function()
      json.decode(42)
    end, "expected a string")
  end)

  t.it("accepts all four whitespace characters", function()
    t.same(decode_ok(' \t\r\n[ 1 ,\n\t2 ] \n'), { 1, 2 })
  end)
end)

t.describe("json nesting", function()
  t.it("decodes and encodes 1000 levels without recursion", function()
    local text = string.rep("[", 1000) .. "7" .. string.rep("]", 1000)
    local v = decode_ok(text)
    local inner = v
    for _ = 1, 999 do
      inner = inner[1]
    end
    t.eq(inner[1], 7)
    t.eq(encode_ok(v), text)
    local objs = string.rep('{"a":', 1000) .. "null" .. string.rep("}", 1000)
    t.eq(encode_ok(decode_ok(objs)), objs)
  end)

  t.it("rejects deeper nesting with a position", function()
    local text = string.rep("[", 1001) .. string.rep("]", 1001)
    local e = t.fails_with("ParseError", json.decode(text))
    t.match(e.message, "nesting deeper than 1000 at position 1001", true)
    local v = decode_ok(string.rep("[", 1000) .. string.rep("]", 1000))
    local inner = v
    for _ = 1, 999 do
      inner = inner[1]
    end
    inner[1] = json.array({})
    t.eq(json.encode(v), nil)
    t.match(t.err(json.encode({ v })).message, "nesting")
  end)
end)

t.describe("json.encode tables", function()
  t.it("sorts object keys", function()
    t.eq(encode_ok({ b = 1, a = 2, c = { z = 1, y = 2 } }), '{"a":2,"b":1,"c":{"y":2,"z":1}}')
  end)

  t.it("treats keys 1..n as an array and anything else as an object", function()
    t.eq(encode_ok({ 1, 2, 3 }), "[1,2,3]")
    t.eq(encode_ok({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}')
    t.eq(encode_ok({ "a", x = 1 }), '{"1":"a","x":1}')
    t.eq(encode_ok({ [1.5] = true }), '{"1.5":true}')
  end)

  t.it("encodes holes in a marked array as null", function()
    local a = json.array({})
    a[1] = 1
    a[3] = 3
    t.eq(encode_ok(a), "[1,null,3]")
  end)

  t.it("refuses a marked array with a non-index key", function()
    local a = json.array({ 1 })
    a.x = 2
    t.match(t.fails_with("InvalidInput", json.encode(a)).message, "non%-index key")
  end)

  t.it("refuses keys that are neither strings nor numbers", function()
    t.match(t.err(json.encode({ [true] = 1 })).message, "key of type boolean")
  end)

  t.it("refuses cycles, functions and userdata-like values", function()
    local a = {}
    a.self = a
    t.match(t.err(json.encode(a)).message, "contains itself")
    t.match(t.err(json.encode({ f = print })).message, "function")
  end)

  t.it("allows the same table twice when it is not a cycle", function()
    local shared = { 1 }
    t.eq(encode_ok({ a = shared, b = shared }), '{"a":[1],"b":[1]}')
  end)

  t.it("refuses a secret without leaking it", function()
    local e = t.fails_with("InvalidInput", json.encode({ key = secret.wrap("sk-CANARY-123") }))
    t.match(e.message, "secret")
    t.no_match(tostring(e), "CANARY", true)
  end)

  t.it("encodes nil at top level as null", function()
    t.eq(encode_ok(nil), "null")
    t.eq(encode_ok(json.null), "null")
  end)

  t.it("pretty-prints like JSON.stringify(v, null, 2)", function()
    local v = decode_ok('{"b":[1,{"c":null}],"a":{},"d":[]}')
    t.eq(
      encode_ok(v, { indent = true }),
      '{\n  "a": {},\n  "b": [\n    1,\n    {\n      "c": null\n    }\n  ],\n  "d": []\n}'
    )
  end)

  t.it("encodes 20,000 elements (gopher-lua concat limit)", function()
    local a = {}
    for i = 1, 20000 do
      a[i] = i
    end
    local text = encode_ok(a)
    local back = decode_ok(text)
    t.eq(#back, 20000)
    t.eq(back[20000], 20000)
  end)
end)

t.describe("json real model", function()
  t.it("decodes models/neon.json and re-encodes it losslessly", function()
    local f = io.open(t.root .. "/models/neon.json", "rb")
    if not f then
      t.fail("models/neon.json is missing")
    end
    local text = f:read("*a")
    f:close()
    local model = decode_ok(text)
    t.eq(model.smithy, "2.0")
    local shapes = 0
    for _ in pairs(model.shapes) do
      shapes = shapes + 1
    end
    t.truthy(shapes > 100, "shape count " .. shapes)
    local again = decode_ok(encode_ok(model))
    t.eq(encode_ok(again), encode_ok(model))
  end)
end)
