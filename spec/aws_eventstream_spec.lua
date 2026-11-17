-- AWS event streams: the message codec (distilled.aws.eventstream) against aws-sdk-go-v2's
-- published vectors and Distilled's codec (spec/golden/aws_eventstream/conform.lua, from
-- verify/lib/aws_eventstream_conform.mjs), event signing against @smithy/signature-v4.
local t = require("spec.harness")
local es = require("distilled.aws.eventstream")
local crypto = require("distilled.crypto")
local V = require("spec.golden.aws_eventstream.conform")

local hex = crypto.hex

local function assert_ok(v, err)
  if v == nil then
    error(err and err.message or "nil", 2)
  end
  return v
end

local WIRE = {
  boolean = nil,
  byte = 2,
  short = 3,
  integer = 4,
  long = 5,
  binary = 6,
  string = 7,
  timestamp = 8,
  uuid = 9,
}

-- a decoded header in the golden view: { name, type = wire number, value | hex }
local function view(h)
  local v = { name = h.name, type = WIRE[h.type] }
  if h.type == "boolean" then
    v.type = h.value and 0 or 1
    v.value = h.value
  elseif h.type == "binary" or h.type == "uuid" then
    v.hex = hex.encode(h.value)
  elseif h.type == "long" or h.type == "timestamp" then
    v.value = string.format("%.0f", h.value)
  else
    v.value = h.value
  end
  return v
end

local function views(headers)
  local out = {}
  for i, h in ipairs(headers) do
    out[i] = view(h)
  end
  return out
end

local function list(x)
  if x and x.n == 0 then
    return {}
  end
  return x
end

-- a golden spec header -> a codec header
local function header_of(h)
  local out = { name = h.name, type = h.type, value = h.value }
  if h.hex then
    out.value = hex.decode(h.hex)
  end
  if h.type == "long" or h.type == "timestamp" then
    out.value = tonumber(h.value)
  end
  return out
end

local function headers_of(hs)
  local out = {}
  for i, h in ipairs(list(hs)) do
    out[i] = header_of(h)
  end
  return out
end

t.describe("aws eventstream codec: aws-sdk-go-v2 vectors", function()
  for _, c in ipairs(V.vectors) do
    t.it(c.id, function()
      local m, err = es.decode_message(hex.decode(c.hex))
      if c.expected.ok then
        t.truthy(m, type(err) == "table" and err.message or nil)
        t.eq(m.total_length, c.expected.total_length)
        t.eq(m.headers_length, c.expected.headers_length)
        t.eq(m.prelude_crc, c.expected.prelude_crc)
        t.eq(m.message_crc, c.expected.message_crc)
        t.eq(hex.encode(m.payload), c.expected.payload_hex)
        t.same(views(m.headers), list(c.expected.headers))
        -- and back: the same bytes
        t.eq(
          hex.encode(assert_ok(es.encode_message({ headers = m.headers, payload = m.payload }))),
          c.hex
        )
      else
        t.eq(m, nil)
        t.eq(err.tag, "ParseError")
        t.eq(err.message, c.distilled.message)
        -- the go vectors name the CRC that fails. corrupted_length makes the message look
        -- longer than the bytes: Distilled checks the length before the prelude CRC (the
        -- stream framer checks the prelude CRC first, see aws_eventstream_stream_spec)
        local which = string.match(c.expected.go_message, "^(%a+) checksum")
        if c.id ~= "negative/corrupted_length" then
          t.match(err.message, "^" .. which .. " CRC mismatch")
        else
          t.match(err.message, "^Incomplete message")
        end
      end
    end)
  end
end)

t.describe("aws eventstream codec: encoding matches Distilled", function()
  for _, c in ipairs(V.encode) do
    t.it(c.id, function()
      local payload = c.payload_hex and hex.decode(c.payload_hex) or ""
      if c.payload_rep then
        local parts = {}
        for _, r in ipairs(c.payload_rep) do
          parts[#parts + 1] = string.rep(hex.decode(r[1]), r[2])
        end
        payload = table.concat(parts)
      end
      local bytes, err = es.encode_message({ headers = headers_of(c.headers), payload = payload })
      if c.expected.ok then
        t.truthy(bytes, err and err.message)
        t.eq(#bytes, c.expected.length)
        t.eq(hex.encode(crypto.sha256(bytes)), c.expected.sha256)
        if c.expected.hex then
          t.eq(hex.encode(bytes), c.expected.hex)
        end
        -- decode it again: same headers, same payload
        local m = assert_ok(es.decode_message(bytes))
        t.eq(m.payload, payload)
        t.eq(#m.headers, #list(c.headers))
      else
        t.eq(bytes, nil)
        t.eq(err.tag, "InvalidInput")
        t.eq(err.message, c.expected.message)
      end
    end)
  end
  for _, c in ipairs(V.encode_events) do
    t.it("event " .. c.id, function()
      local e = c.event
      local ev = {
        kind = ({ MessageEvent = "event", ExceptionEvent = "exception", ErrorEvent = "error" })[e._tag],
        event_type = e.eventType,
        exception_type = e.exceptionType,
        content_type = e.contentType,
        error_code = e.errorCode,
        error_message = e.errorMessage,
        payload = hex.decode(e.payload or ""),
        headers = headers_of(e.headers),
      }
      t.eq(hex.encode(assert_ok(es.encode_event(ev))), c.expected.hex)
    end)
  end
end)

t.describe("aws eventstream codec: decoding matches Distilled", function()
  for _, c in ipairs(V.decode) do
    t.it(c.id, function()
      local x = c.expected
      local m, err = es.decode_message(hex.decode(c.hex))
      if not x.ok and x.stage == "message" then
        t.eq(m, nil)
        t.eq(err.tag, "ParseError")
        t.eq(err.message, x.message)
        return
      end
      t.truthy(m, type(err) == "table" and err.message or nil)
      local want = x.ok and x.message or x.decoded
      t.eq(select(2, es.decode_message(hex.decode(c.hex))), want.consumed)
      t.eq(hex.encode(m.payload), want.payload_hex)
      t.same(views(m.headers), list(want.headers))
      local ev, eerr = es.parse_event(m)
      if not x.ok then
        t.eq(ev, nil)
        t.eq(eerr.tag, "ParseError")
        t.eq(eerr.message, x.message)
        return
      end
      t.truthy(ev, eerr and eerr.message)
      t.eq(ev.kind, x.event.kind)
      t.eq(ev.event_type, x.event.event_type)
      t.eq(ev.exception_type, x.event.exception_type)
      t.eq(ev.content_type, x.event.content_type)
      t.eq(ev.error_code, x.event.error_code)
      t.eq(ev.error_message, x.event.error_message)
    end)
  end

  t.it("message_length waits for a whole message", function()
    local bytes = assert_ok(es.encode_message({ headers = {}, payload = "abc" }))
    t.eq(es.message_length(""), 0)
    t.eq(es.message_length(string.sub(bytes, 1, 11)), 0)
    t.eq(es.message_length(string.sub(bytes, 1, #bytes - 1)), 0)
    t.eq(es.message_length(bytes .. "xyz"), #bytes)
  end)

  t.it("long values beyond 2^53 survive a round trip through raw", function()
    local raw = "\127\255\255\255\255\255\255\255" -- 2^63 - 1
    local m = assert_ok(es.decode_message(assert_ok(es.encode_message({
      headers = { { name = "l", type = "long", value = 0, raw = raw } },
    }))))
    t.eq(m.headers[1].raw, raw)
  end)

  t.it("refuses values a type cannot hold", function()
    for _, h in ipairs({
      { name = "b", type = "byte", value = 128 },
      { name = "s", type = "short", value = 1.5 },
      { name = "i", type = "integer", value = 2147483648 },
      { name = "u", type = "uuid", value = "short" },
      { name = "x", type = "string", value = string.rep("x", 65536) },
      { name = "y", type = "nope", value = 1 },
      { name = "z", type = "boolean", value = "yes" },
    }) do
      local bytes, err = es.encode_message({ headers = { h } })
      t.eq(bytes, nil)
      t.eq(err.tag, "InvalidInput")
      t.match(err.message, "^Header " .. h.name .. ": ")
    end
  end)
end)

t.describe("aws eventstream signing: @smithy/signature-v4 signMessage", function()
  local sigv4 = require("distilled.sigv4")
  local S = V.signing
  for _, c in ipairs(S.cases) do
    t.it(c.id, function()
      local date = string.sub(sigv4.amz_datetime(c.epoch_ms / 1000), 1, 8)
      local key = sigv4.signing_key(S.secret_access_key, date, S.region, S.service)
      local frame, signature = es.sign_frame({
        payload = hex.decode(c.payload_hex),
        prior_signature = c.prior,
        signing_key = key,
        scope = date .. "/" .. S.region .. "/" .. S.service .. "/aws4_request",
        epoch_ms = c.epoch_ms,
      })
      t.eq(signature, c.expected.signature)
      t.eq(hex.encode(frame), c.expected.frame_hex)
    end)
  end
end)
