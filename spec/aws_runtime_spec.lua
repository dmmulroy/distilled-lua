-- The AWS runtime pieces below the protocols: the endpoint rules interpreter against
-- the models' own endpointTests (a sample of services, through the rule sets the
-- generated clients ship; verify/lib/aws_endpoint_tests.lua runs all 14,000 cases),
-- gzip (checked by an inflater written here), SigV2 encoding, error-code sanitising
-- and the code table.
local t = require("spec.harness")
local json = require("distilled.json")
local endpoint = require("distilled.aws.endpoint")
local gzip = require("distilled.aws.gzip")
local crc32 = require("distilled.crypto.crc32")
local compat = require("distilled.compat")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

t.describe("aws endpoint rules: the models' endpointTests", function()
  local cases = json.decode(read(t.root .. "/spec/fixtures/aws/endpoint-tests.json"))
  local names = {}
  for name in pairs(cases) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    t.it(name .. ": " .. #cases[name] .. " cases", function()
      local text = require("aws." .. name .. ".endpoints")
      local rules = type(text) == "string" and json.decode(text) or text
      local failures = {}
      for i, case in ipairs(cases[name]) do
        local params = {}
        for k, v in pairs(case.params or {}) do
          if v ~= json.null then
            params[k] = v
          end
        end
        local got, err = endpoint.resolve(rules, params)
        local want = case.expect or {}
        local why
        if want.error ~= nil then
          if got then
            why = "wanted error " .. want.error .. ", got " .. got.url
          elseif err ~= want.error then
            why = "wanted error " .. want.error .. ", got " .. tostring(err)
          end
        else
          local e = want.endpoint or {}
          if not got then
            why = "wanted " .. tostring(e.url) .. ", got error " .. tostring(err)
          elseif got.url ~= e.url then
            why = "url " .. got.url .. " ~= " .. tostring(e.url)
          elseif json.encode(got.properties) ~= json.encode(e.properties or {}) then
            why = "properties " .. json.encode(got.properties)
          elseif json.encode(got.headers) ~= json.encode(e.headers or {}) then
            why = "headers " .. json.encode(got.headers)
          end
        end
        if why then
          failures[#failures + 1] = "#" .. i .. ": " .. why
        end
      end
      if #failures > 0 then
        t.fail(table.concat(failures, "\n"))
      end
    end)
  end

  t.it("a missing required parameter is an error, not a raise", function()
    local rules = json.decode(require("aws.sts.endpoints"))
    local got, err = endpoint.resolve(rules, {})
    t.eq(got, nil)
    t.match(err, "Missing Region", true)
  end)
end)

-- A fixed-Huffman inflater (RFC 1951 3.2.6), the decoder side of aws/gzip.lua's encoder.
local function inflate_fixed(data, pos)
  local bitbuf, bitcnt = 0, 0
  local function bits(n)
    while bitcnt < n do
      bitbuf = bitbuf + string.byte(data, pos) * 2 ^ bitcnt
      pos = pos + 1
      bitcnt = bitcnt + 8
    end
    local v = bitbuf % 2 ^ n
    bitbuf = (bitbuf - v) / 2 ^ n
    bitcnt = bitcnt - n
    return v
  end
  -- a Huffman code is read most significant bit first
  local function code(n)
    local c = 0
    for _ = 1, n do
      c = c * 2 + bits(1)
    end
    return c
  end
  local function symbol()
    local c = code(7)
    if c <= 23 then
      return 256 + c
    end
    c = c * 2 + bits(1)
    if c >= 48 and c <= 191 then
      return c - 48
    elseif c >= 192 and c <= 199 then
      return 280 + c - 192
    end
    c = c * 2 + bits(1)
    return 144 + c - 400
  end
  local LBASE = {
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
    13,
    15,
    17,
    19,
    23,
    27,
    31,
    35,
    43,
    51,
    59,
    67,
    83,
    99,
    115,
    131,
    163,
    195,
    227,
    258,
  }
  local LEXTRA =
    { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
  local final = bits(1)
  local btype = bits(2)
  assert(final == 1 and btype == 1, "one final fixed-Huffman block")
  local out = {}
  while true do
    local s = symbol()
    if s < 256 then
      out[#out + 1] = string.char(s)
    elseif s == 256 then
      break
    else
      local li = s - 256
      local len = LBASE[li] + bits(LEXTRA[li])
      local dc = code(5)
      local extra = dc < 2 and 0 or math.floor(dc / 2) - 1
      local base = 1
      for c = 0, dc - 1 do
        base = base + 2 ^ (c < 2 and 0 or math.floor(c / 2) - 1)
      end
      local dist = base + bits(extra)
      for _ = 1, len do
        out[#out + 1] = out[#out - dist + 1]
      end
    end
  end
  -- compat.concat: gopher-lua's table.concat fails past ~2,500 items
  return compat.concat(out), pos
end

local function le32(s, i)
  local a, b, c, d = string.byte(s, i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

t.describe("aws gzip (requestCompression)", function()
  local function round_trip(text)
    local z = gzip.compress(text)
    t.eq(string.sub(z, 1, 4), "\31\139\8\0")
    local back, pos = inflate_fixed(z, 11)
    t.eq(#back, #text)
    t.truthy(back == text, "inflates to the input")
    t.eq(le32(z, pos), crc32.crc32(text))
    t.eq(le32(z, pos + 4), #text)
    return z
  end

  t.it("round trips the empty string, short text and long repeats", function()
    round_trip("")
    round_trip("a")
    round_trip("aaaa")
    round_trip(string.rep("abcabcabd", 2000))
  end)

  t.it("compresses a metric payload well, and handles every byte value", function()
    local parts = {}
    for i = 1, 300 do
      parts[i] = '{"MetricName":"metric-' .. i .. '","Value":' .. i .. ',"Unit":"Count"}'
    end
    local text = "[" .. compat.concat(parts, ",") .. "]"
    local z = round_trip(text)
    t.truthy(#z < #text / 3, "smaller than a third: " .. #z .. " of " .. #text)
    local bytes = {}
    for i = 0, 255 do
      bytes[#bytes + 1] = string.char(i)
    end
    round_trip(compat.concat(bytes) .. compat.concat(bytes))
  end)
end)

t.describe("aws SigV2 and error codes", function()
  t.it("SigV2 encodes RFC 3986 (encodeURIComponent plus !'()*)", function()
    local sigv2 = require("distilled.aws.sigv2")
    t.eq(sigv2.rfc3986("a b!'()*~-_.:/"), "a%20b%21%27%28%29%2A~-_.%3A%2F")
    t.eq(sigv2.timestamp(1700000000), "2023-11-14T22:13:20Z")
  end)

  t.it("sanitize_error_code: first of a list, before ':', after '#'", function()
    local s = require("distilled.aws.json_protocols").sanitize_error_code
    t.eq(s("FooError"), "FooError")
    t.eq(s("FooError:http://internal.amazon.com/coral/com.amazon.coral.validate/"), "FooError")
    t.eq(s("aws.protocoltests.restjson#FooError"), "FooError")
    t.eq(s("aws.protocoltests.restjson#FooError:http://internal.amazon.com/coral/"), "FooError")
    t.eq(s("FooError, BarError"), "FooError")
  end)

  t.it("the code table: a declared class, a common one, the suffix rule", function()
    local aws_errors = require("distilled.aws.errors")
    local service = require("aws.dynamodb.service")
    local op = service.ops.put_item
    local tbl = aws_errors.table_for(op, service, {})
    t.eq(
      aws_errors.match(tbl, "ConditionalCheckFailedException", 400, "x").tag,
      "ConditionalCheckFailedException"
    )
    t.eq(aws_errors.match(tbl, "ThrottlingException", 400, "x").tag, "ThrottlingException")
    t.eq(
      aws_errors.match(tbl, "ConditionalCheckFailed", 400, "x").tag,
      "ConditionalCheckFailedException"
    )
    local cls, fallback = aws_errors.match(tbl, "NothingLikeThis", 400, "x")
    t.eq(cls, nil)
    t.eq(fallback, nil)
  end)
end)
