-- AWS event stream operations replayed against Distilled (spec/golden/aws_eventstream/
-- conform.lua, written by verify/lib/aws_eventstream_conform.mjs): the same canned event
-- stream bytes through the generated clients, over a stub streaming transport.
--
-- Where this runtime differs on purpose (aws/stream.lua's header lists them), the case's
-- expectation is adjusted in INTENDED below, with the reason; everything else must match
-- Distilled's output exactly.
local t = require("spec.harness")
local stub = require("spec.aws_eventstream_stub")
local crypto = require("distilled.crypto")
local es = require("distilled.aws.eventstream")
local json = require("distilled.json")
local secret = require("distilled.secret")
local V = require("spec.golden.aws_eventstream.conform")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local hex = crypto.hex
local CREDS = {
  access_key_id = "AKIAIOSFODNN7EXAMPLE",
  secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}

local function views(headers)
  local out = {}
  for i, h in ipairs(headers) do
    out[i] = { name = h.name, type = h.type, value = h.value }
  end
  return out
end

local function lua_module(service)
  if service == "s3" then
    return "s3"
  end
  return "aws." .. string.gsub(service, "-", "_")
end

local function snake(s)
  s = string.gsub(s, "(%l)(%u)", "%1_%2")
  s = string.gsub(s, "(%d)(%u)", "%1_%2")
  return string.lower(s)
end

-- golden view -> Lua value: { $hex } bytes, { $redacted } a marker, { n = 0 } an empty list
local function expected(v)
  if type(v) ~= "table" then
    return v
  end
  if v["$hex"] then
    return hex.decode(v["$hex"])
  end
  if v["$redacted"] ~= nil then
    return { __secret = expected(v["$redacted"]) }
  end
  if v.n == 0 and next(v, nil) == "n" and next(v, "n") == nil then
    return {}
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = expected(x)
  end
  return out
end

-- a Lua value in the same form: secrets as the marker, json markers dropped
local function actual(v, depth)
  depth = depth or 0
  if depth > 30 then
    return "<deep>"
  end
  if secret.is(v) then
    return { __secret = actual(secret.unwrap(v), depth + 1) }
  end
  if type(v) ~= "table" or v == json.null then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = actual(x, depth + 1)
  end
  return out
end

-- golden input -> Lua input ($hex -> bytes)
local function input_of(v)
  if type(v) ~= "table" then
    return v
  end
  if v["$hex"] then
    return hex.decode(v["$hex"])
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = input_of(x)
  end
  if v.n == 0 then
    return json.array({})
  end
  return out
end

local function client_for(service, transport)
  local Client = require(lua_module(service))
  return Client.new({
    host = {
      transport = transport,
      epoch = function()
        return 1700000000
      end,
      random = function()
        return 0.5
      end,
    },
    region = "us-east-1",
    credentials = require("distilled.aws.credentials").static(CREDS),
  })
end

-- the union members that are errors: Distilled yields them as events, this runtime ends
-- the stream with the class
local function error_member(client, op, item)
  local st = client._state
  local d = require("distilled.aws.stream").derived(op, st.service.shapes)
  for name, fields in pairs(item) do
    if name == "UnmodeledError" then
      return { tag = fields.errorCode, message = fields.errorMessage, fields = {} }
    end
    local m = d.members[name]
    if m and m.error then
      local f = {}
      for k, v in pairs(fields) do
        if k ~= "message" then
          f[k] = v
        end
      end
      return { tag = m.error, message = fields.message, fields = f }
    end
  end
  return nil
end

-- Distilled's outcome, rewritten where this runtime differs on purpose
local INTENDED = {
  -- Distilled decodes every message of a chunk before emitting any, so a bad CRC in the
  -- last message also loses the valid one before it; here each message is emitted as it
  -- is read
  ["bedrock-converse-bad-crc"] = function(x)
    x.events = { { messageStart = { role = "assistant" } } }
  end,
  -- an empty body is an event stream with no events (Distilled: "can not create stream
  -- from empty body")
  ["bedrock-converse-empty"] = function(x)
    x.error = nil
  end,
  ["transcribe-configuration"] = function(x)
    x.error = nil
  end,
  -- the RPC protocols' initial-response fills stream.output; Distilled yields it
  ["kinesis-subscribe"] = function(x)
    table.remove(x.events, 1)
  end,
  -- S3 Select: Distilled's XML payload parser drops the Records bytes and the Stats
  -- document (it decodes them as the event structure, not its @eventPayload member)
  ["s3-select"] = function(x)
    x.events = {
      { Records = { Payload = "a,b\n1,2\n" } },
      { Stats = { Details = { BytesScanned = 100, BytesProcessed = 90, BytesReturned = 8 } } },
      { End = {} },
    }
  end,
  -- @eventHeader members are read from the message headers (Distilled leaves them out)
  ["sagemaker-bidirectional"] = function(x)
    x.events[1].PayloadPart.DataType = "UTF8"
    x.events[1].PayloadPart.CompletionState = "COMPLETE"
  end,
}

local function drain(s)
  local items = {}
  for _ = 1, 1000 do
    local item, err = stub.next(s)
    if item == nil then
      return items, err
    end
    items[#items + 1] = item
  end
  return items, "too many items"
end

local function check_outcome(c, client, op, s, err)
  local x = expected(c.expected)
  if INTENDED[c.id] then
    INTENDED[c.id](x)
  end
  if not x.ok then
    t.eq(s, nil)
    t.eq(err.tag, x.error.tag)
    t.eq(err.message, x.error.message)
    return
  end
  t.truthy(s, err and err.message)
  -- a duplex stream reads the response head on the first next(): drain, then compare
  local items, ierr = drain(s)
  t.same(actual(s.output), x.output, "output")
  -- Distilled's error members become the error that ends the stream
  local want_err = x.error
  local events = {}
  for _, e in ipairs(x.events or {}) do
    local em = error_member(client, op, e)
    if em then
      want_err = em
      break
    end
    events[#events + 1] = e
  end
  t.same(actual(items), events, "events")
  if want_err then
    t.truthy(ierr, "the stream should end with " .. tostring(want_err.tag))
    if want_err.tag == "EventStreamDecodeError" then
      t.eq(ierr.tag, "ParseError")
    else
      t.eq(ierr.tag, want_err.tag)
    end
    t.eq(ierr.message, want_err.message)
    for k, v in pairs(want_err.fields or {}) do
      t.same(actual(ierr[k]), v, "error field " .. k)
    end
  else
    t.eq(ierr, nil)
  end
end

t.describe("aws event streams vs Distilled: output streams", function()
  for _, c in ipairs(V.outputs) do
    t.it(c.id, function()
      local transport, log = stub.stream_transport({
        status = c.response.status,
        headers = c.response.headers,
        body = hex.decode(c.response.body_hex),
      })
      local client = client_for(c.service, transport)
      local method = snake(c.op)
      local op = client._state.service.ops[method]
      local s, err = stub.open(client, method, input_of(c.input))
      local req = log.requests[1]
      t.truthy(req, "a request was sent")
      t.eq(req.method, c.request.method)
      t.eq(req.url, c.request.url)
      -- the signed request: every header Distilled sends (the signature included), but
      -- the user agent and the Content-Length the transport adds, and the signature of a
      -- JSON body whose keys are in another order (sorted here, as in all AWS clients)
      local body = hex.decode(c.request.body_hex or "")
      for k, v in pairs(c.request.headers) do
        -- a JSON body with its keys in another order is signed differently
        local signed_body = k == "authorization" and req.body ~= body
        if k ~= "user-agent" and k ~= "content-length" and not signed_body then
          t.eq(req.headers[k], v, "header " .. k)
        end
      end
      if req.body ~= body then
        -- JSON documents: the same value (keys are sorted here)
        t.same(json.decode(req.body or ""), json.decode(body), "request body")
      end
      check_outcome(c, client, op, s, err)
      if s then
        s:close()
        t.truthy(log.readers[1].closed, "close() closes the reader")
      end
    end)
  end

  t.it("a plain call collects the events into the stream member", function()
    local c = V.outputs[3] -- bedrock-converse-stream
    local transport = stub.stream_transport({
      status = 200,
      headers = c.response.headers,
      body = hex.decode(c.response.body_hex),
    })
    local client = client_for(c.service, transport)
    local out, err = client:converse_stream(input_of(c.input))
    t.truthy(out, err and err.message)
    t.same(actual(out.stream), expected(c.expected.events))
  end)

  t.it("a plain call of a bidirectional operation is refused", function()
    local transport = stub.stream_transport({ status = 200, body = "" })
    local client = client_for("transcribe-streaming", transport)
    t.fails_with(
      "SdkError",
      client:start_stream_transcription({
        LanguageCode = "en-US",
        MediaSampleRateHertz = 16000,
        MediaEncoding = "pcm",
      })
    )
  end)
end)

t.describe("aws event streams vs Distilled: input streams", function()
  for _, c in ipairs(V.inputs) do
    t.it(c.id, function()
      local transport, log = stub.duplex_transport({
        status = c.response.status,
        headers = c.response.headers,
        body = hex.decode(c.response.body_hex),
      })
      local client = client_for(c.service, transport)
      local method = snake(c.op)
      local op = client._state.service.ops[method]
      local s, err = stub.open(client, method, input_of(c.input))
      t.truthy(s, err and err.message)
      local req = log.requests[1]
      t.eq(req.method, c.request.method)
      t.eq(req.url, c.request.url)
      -- the headers Distilled sends, but the payload hash: STREAMING-AWS4-HMAC-SHA256-EVENTS
      -- here (signed events) where Distilled sends UNSIGNED-PAYLOAD (unsigned events)
      for k, v in pairs(c.request.headers) do
        if k ~= "authorization" and k ~= "x-amz-content-sha256" and k ~= "user-agent" then
          t.eq(req.headers[k], v, "header " .. k)
        end
      end
      t.eq(req.headers["x-amz-content-sha256"], "STREAMING-AWS4-HMAC-SHA256-EVENTS")
      t.match(req.headers.authorization, "^AWS4%-HMAC%-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/")
      t.eq(req.body, nil)
      for _, e in ipairs(c.events) do
        t.truthy(s:send(input_of(e)))
      end
      t.truthy(s:close_input())
      t.truthy(log.input_closed)
      -- every frame is a signed envelope around Distilled's event message; the last is empty
      t.eq(#log.written, #c.frames + 1)
      local sigv4 = require("distilled.sigv4")
      local prior = string.match(req.headers.authorization, "Signature=(%x+)$")
      local region, svc =
        string.match(req.headers.authorization, "Credential=[^/]+/%d+/([^/]+)/([^/]+)/")
      local key = sigv4.signing_key(CREDS.secret_access_key, "20231114", region, svc)
      for i, frame in ipairs(log.written) do
        local m = assert(es.decode_message(frame))
        t.eq(m.headers[1].name, ":date")
        t.eq(m.headers[1].value, 1700000000000)
        t.eq(m.headers[2].name, ":chunk-signature")
        -- Distilled's event message, byte for byte, except the order of JSON object keys
        -- (sorted here, as everywhere in the AWS runtime; Distilled keeps the schema's)
        local want = c.frames[i]
        if want == nil then
          t.eq(m.payload, "", "the last frame is empty")
        elseif m.payload ~= hex.decode(want) then
          local inner = assert(es.decode_message(m.payload))
          local theirs = assert(es.decode_message(hex.decode(want)))
          t.same(views(inner.headers), views(theirs.headers), "frame " .. i .. " headers")
          t.eq(es.string_header(inner.headers, ":content-type"), "application/json")
          t.same(json.decode(inner.payload), json.decode(theirs.payload), "frame " .. i .. " JSON")
        end
        local again, sig = es.sign_frame({
          payload = m.payload,
          prior_signature = prior,
          signing_key = key,
          scope = "20231114/" .. region .. "/" .. svc .. "/aws4_request",
          epoch_ms = 1700000000000,
        })
        t.eq(again, frame, "frame " .. i .. " is signed over the previous signature")
        prior = sig
      end
      check_outcome(c, client, op, s, nil)
      s:close()
      t.truthy(log.closed)
    end)
  end
end)
