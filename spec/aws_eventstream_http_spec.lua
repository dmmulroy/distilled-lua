-- AWS event streams over the real hosts (distilled.host.popen on lua/luajit,
-- distilled.host.rex in Rex) against `dl serve` (verify/lib/serve_eventstream.py, gated
-- on DL_SERVE_URL: run with `verify/dl test --http`):
--   * an output stream is delivered as it arrives: the first event is in hand while the
--     server has not yet sent the second (the server's own log says so);
--   * both ways: each input event is sent, signed, and its reply read before the next
--     event is sent; the server verifies every :chunk-signature, the empty end frame's
--     too; binary payloads arrive intact;
--   * a dropped connection mid-stream and an HTTP error before it.
local t = require("spec.harness")
local serve = require("verify.lib.serve")
local es = require("distilled.aws.eventstream")
local json = require("distilled.json")
local crypto = require("distilled.crypto")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local SECRET = "eventstreamtestsecret"

local function ok(v, err)
  if v == nil then
    error(type(err) == "table" and tostring(err.message) or tostring(err), 2)
  end
  return v
end

local function event(event_type, payload)
  return ok(es.encode_message({
    headers = {
      es.string(":message-type", "event"),
      es.string(":event-type", event_type),
      es.string(":content-type", "application/json"),
    },
    payload = payload,
  }))
end

t.describe("aws event streams over HTTP (dl serve)", function()
  if not serve.url() then
    t.pending("DL_SERVE_URL is not set (run verify/dl test --http)")
    return
  end
  local in_rex = rawget(_G, "rex") ~= nil
  local host = in_rex and require("distilled.host.rex")() or require("distilled.host.popen")()
  local plain = host.transport

  local function control(method, path, value)
    local body = value ~= nil and json.encode(value) or nil
    local res = ok(plain({
      method = method,
      url = serve.url() .. path,
      headers = body and { ["content-type"] = "application/json" } or {},
      body = body,
      timeout = 10,
    }))
    t.eq(res.status, 200, path)
    return res.body ~= "" and json.decode(res.body) or nil
  end

  local function log_for(path)
    for _, e in ipairs(control("GET", "/_dl/eventstream/log")) do
      if e.path == path then
        return e
      end
    end
    return nil
  end

  local function client(module, endpoint)
    return require(module).new({
      host = host,
      endpoint = endpoint,
      region = "us-east-1",
      credentials = require("distilled.aws.credentials").static({
        access_key_id = "AKIDEXAMPLE",
        secret_access_key = SECRET,
      }),
    })
  end

  local function open(c, method, input)
    return require("spec.aws_eventstream_stub").open(c, method, input)
  end

  t.it("the host transports have stream and duplex entry points", function()
    t.eq(type(plain.stream), "function")
    t.eq(type(plain.duplex), "function")
  end)

  t.it("an output stream's events arrive one at a time", function()
    control("POST", "/_dl/eventstream/reset")
    local path = "/esh1/model/m/converse-stream"
    control("POST", "/_dl/eventstream/script", {
      path = path,
      delay = 1.5,
      frames_b64 = json.array({
        crypto.base64.encode(event("messageStart", '{"role":"assistant"}')),
        crypto.base64.encode(
          event("contentBlockDelta", '{"contentBlockIndex":0,"delta":{"text":"Hi"}}')
        ),
        crypto.base64.encode(event("messageStop", '{"stopReason":"end_turn"}')),
      }),
    })
    local c = client("aws.bedrock_runtime", serve.url() .. "/esh1")
    local s = ok(open(c, "converse_stream", { modelId = "m", messages = json.array({}) }))
    t.eq(s.status, 200)
    local first = ok(s:next())
    t.eq(first.messageStart.role, "assistant")
    -- the server has sent one frame so far: the event was read before the next was sent
    t.eq(#log_for(path).sent, 1, "frames sent when the first event was read")
    local second = ok(s:next())
    t.eq(second.contentBlockDelta.delta.text, "Hi")
    t.eq(#log_for(path).sent, 2, "frames sent when the second event was read")
    t.eq(ok(s:next()).messageStop.stopReason, "end_turn")
    local done, err = s:next()
    t.eq(done, nil)
    t.eq(err, nil)
    s:close()
  end)

  t.it("a connection dropped mid-stream ends the stream with an error", function()
    local path = "/esh2/model/m/converse-stream"
    control("POST", "/_dl/eventstream/script", {
      path = path,
      drop_after = 1,
      frames_b64 = json.array({
        crypto.base64.encode(event("messageStart", '{"role":"assistant"}')),
        crypto.base64.encode(event("messageStop", '{"stopReason":"end_turn"}')),
      }),
    })
    local c = client("aws.bedrock_runtime", serve.url() .. "/esh2")
    local s = ok(open(c, "converse_stream", { modelId = "m", messages = json.array({}) }))
    ok(s:next())
    local item, err = s:next()
    t.eq(item, nil)
    t.truthy(err, "an error")
    t.truthy(err.tag == "TransportError" or err.tag == "ParseError", tostring(err.tag))
    s:close()
  end)

  t.it("an HTTP error before the stream is the operation's error", function()
    local path = "/esh3/model/m/converse-stream"
    control("POST", "/_dl/eventstream/script", {
      path = path,
      status = 400,
      headers = {
        ["x-amzn-errortype"] = "ValidationException",
        ["content-type"] = "application/json",
      },
      frames_b64 = json.array({ crypto.base64.encode('{"message":"bad model"}') }),
    })
    local c = client("aws.bedrock_runtime", serve.url() .. "/esh3")
    local s, err = open(c, "converse_stream", { modelId = "m", messages = json.array({}) })
    t.eq(s, nil)
    t.eq(err.tag, "ValidationException")
    t.eq(err.message, "bad model")
  end)

  t.it("both ways: each signed event is answered before the next is sent", function()
    control("POST", "/_dl/eventstream/reset")
    local base = "/_dl/eventstream/duplex/HeartbeatEvent/eventId/" .. SECRET
    local c = client("aws.lex_runtime_v2", serve.url() .. base)
    local s = ok(open(c, "start_conversation", {
      botId = "B",
      botAliasId = "A",
      localeId = "en_US",
      sessionId = "s1",
      conversationMode = "TEXT",
    }))
    local function reply()
      local item = ok(s:next())
      local n, event_type, verdict, inner =
        string.match(item.HeartbeatEvent.eventId, "^(%d+)|([^|]*)|(%a+)|(%x*)$")
      return tonumber(n), event_type, verdict, crypto.hex.decode(inner)
    end
    ok(s:send({ TextInputEvent = { text = "book a hotel", eventId = "e1" } }))
    local n, event_type, verdict, inner = reply()
    t.eq(n, 1)
    t.eq(event_type, "TextInputEvent")
    t.eq(verdict, "ok", "the first event's signature chains to the request's")
    t.same(json.decode(inner), { text = "book a hotel", eventId = "e1" })
    ok(s:send({ DisconnectionEvent = { eventId = "e2" } }))
    n, event_type, verdict = reply()
    t.eq(n, 2)
    t.eq(event_type, "DisconnectionEvent")
    t.eq(verdict, "ok")
    ok(s:close_input())
    local done, err = s:next()
    t.eq(done, nil)
    t.eq(err, nil)
    s:close()
    local entry = log_for(
      "/_dl/eventstream/duplex/HeartbeatEvent/eventId/"
        .. SECRET
        .. "/bots/B/botAliases/A/botLocales/en_US/sessions/s1/conversation"
    )
    t.truthy(entry, "the server saw the transfer")
    t.eq(#entry.frames, 3)
    for _, f in ipairs(entry.frames) do
      t.eq(f.signature_ok, true, "frame " .. f.n)
    end
    t.eq(entry.frames[3].inner_length, 0, "the end frame is empty")
    t.eq(entry.headers["x-amz-content-sha256"], "STREAMING-AWS4-HMAC-SHA256-EVENTS")
    t.eq(entry.headers["content-type"], "application/vnd.amazon.eventstream")
    t.eq(entry.unterminated, nil)
  end)

  t.it("both ways: binary event payloads arrive intact", function()
    local base = "/_dl/eventstream/duplex/PayloadPart/x/" .. SECRET
    local c = client("aws.sagemaker_runtime_http2", serve.url() .. base)
    local s = ok(open(c, "invoke_endpoint_with_bidirectional_stream", { EndpointName = "ep" }))
    local all = serve.pattern_bytes(256 * 3)
    ok(s:send({ PayloadPart = { Bytes = all, DataType = "BINARY" } }))
    local item = ok(s:next())
    local bytes = require("distilled.secret").unwrap_deep(item.PayloadPart).Bytes
    local summary = json.decode(bytes).x
    local n, event_type, verdict, inner = string.match(summary, "^(%d+)|([^|]*)|(%a+)|(%x*)$")
    t.eq(n, "1")
    t.eq(event_type, "PayloadPart")
    t.eq(verdict, "ok")
    t.eq(crypto.hex.decode(inner), all)
    ok(s:close_input())
    t.eq(s:next(), nil)
    s:close()
  end)
end)
