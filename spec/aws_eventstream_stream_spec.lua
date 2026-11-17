-- AWS event streams: the framing on a reader (distilled.stream.aws_eventstream) and the
-- streaming operations (distilled.aws.stream) on their error, empty and edge paths.
local t = require("spec.harness")
local stub = require("spec.aws_eventstream_stub")
local es = require("distilled.aws.eventstream")
local framing = require("distilled.stream.aws_eventstream")
local json = require("distilled.json")
local secret = require("distilled.secret")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function ok(v, err)
  if v == nil then
    error(err and tostring(err.message) or "nil", 2)
  end
  return v
end

local function event(event_type, payload, extra)
  local headers = {
    es.string(":message-type", "event"),
    es.string(":event-type", event_type),
    es.string(":content-type", "application/json"),
  }
  for _, h in ipairs(extra or {}) do
    headers[#headers + 1] = h
  end
  return ok(es.encode_message({ headers = headers, payload = payload or "" }))
end

local function client_for(module, transport, extra)
  local Client = require(module)
  local o = {
    host = {
      transport = transport,
      epoch = function()
        return 1700000000
      end,
      name = "stub",
    },
    region = "us-east-1",
    credentials = require("distilled.aws.credentials").static({
      access_key_id = "AKIDEXAMPLE",
      secret_access_key = "SECRET",
    }),
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return Client.new(o)
end

local CONVERSE = { modelId = "m", messages = json.array({}) }

t.describe("aws eventstream framing on a reader", function()
  t.it("reads messages one at a time, two read_exact calls each", function()
    local body = event("a", "{}") .. event("b", '{"x":1}')
    local r = stub.reader(body)
    local next_message = framing.messages(r)
    local m1 = ok(next_message())
    t.eq(es.string_header(m1.headers, ":event-type"), "a")
    t.eq(r.reads, 2)
    local m2 = ok(next_message())
    t.eq(m2.payload, '{"x":1}')
    t.eq(r.reads, 4)
    local m3, err = next_message()
    t.eq(m3, nil)
    t.eq(err, nil)
    -- and stays ended
    t.eq(next_message(), nil)
  end)

  t.it("an empty body is a stream with no messages", function()
    local m, err = framing.messages(stub.reader(""))()
    t.eq(m, nil)
    t.eq(err, nil)
  end)

  t.it("a corrupted length fails on the prelude CRC, before reading the rest", function()
    local body = event("a", "{}")
    body = string.char(0, 0, 0x10, 0) .. string.sub(body, 5) -- total_length 4096
    local r = stub.reader(body)
    local m, err = framing.messages(r)()
    t.eq(m, nil)
    t.eq(err.tag, "ParseError")
    t.match(err.message, "^Prelude CRC mismatch")
    t.eq(r.reads, 1)
  end)

  t.it("refuses a total length past the codec's limits", function()
    local prelude = es.u32(framing.MAX_MESSAGE_LENGTH + 1) .. es.u32(0)
    prelude = prelude .. es.u32(require("distilled.crypto.crc32").crc32(prelude))
    local m, err = framing.messages(stub.reader(prelude .. "xxxx"))()
    t.eq(m, nil)
    t.match(err.message, "exceeds the %d+%-byte maximum")
  end)

  t.it("a body that ends inside a message is Distilled's incomplete-data error", function()
    local body = event("a", "{}")
    for _, cut in ipairs({ 5, 12, #body - 1 }) do
      local m, err = framing.messages(stub.reader(string.sub(body, 1, cut)))()
      t.eq(m, nil)
      t.eq(err.tag, "ParseError")
      t.eq(err.message, "Stream ended with " .. cut .. " bytes of incomplete message data")
    end
  end)

  t.it("a transport error mid-stream passes through", function()
    local body = event("a", "{}") .. event("b", "{}")
    local next_message = framing.messages(stub.reader(body, { fail_after = #body - 3 }))
    ok(next_message())
    local m, err = next_message()
    t.eq(m, nil)
    t.eq(err.tag, "TransportError")
  end)

  t.it("next_event parses each message (event, exception, error)", function()
    local body = event("a", "{}")
      .. ok(es.encode_event({ kind = "exception", exception_type = "X", payload = "{}" }))
      .. ok(es.encode_event({ kind = "error", error_code = "C", error_message = "m" }))
    local next_message = framing.messages(stub.reader(body))
    t.eq(ok(framing.next_event(next_message)).kind, "event")
    t.eq(ok(framing.next_event(next_message)).exception_type, "X")
    local e = ok(framing.next_event(next_message))
    t.eq(e.error_code, "C")
    t.eq(e.error_message, "m")
  end)
end)

t.describe("aws event stream operations: edge paths", function()
  t.it("a transport with no stream entry point is a ConfigError", function()
    local client = client_for("aws.bedrock_runtime", function()
      return { status = 200, headers = {}, body = "" }
    end)
    t.fails_with("ConfigError", stub.open(client, "converse_stream", CONVERSE))
  end)

  t.it("a bidirectional operation without a duplex transport names the host limit", function()
    local transport = stub.stream_transport({ status = 200, body = "" })
    local client = client_for("aws.transcribe_streaming", transport)
    local s, err = stub.open(client, "start_stream_transcription", {
      LanguageCode = "en-US",
      MediaSampleRateHertz = 16000,
      MediaEncoding = "pcm",
    })
    t.eq(s, nil)
    t.eq(err.tag, "SdkError")
    t.match(err.message, "duplex transport")
    t.match(err.message, "stub")
  end)

  t.it("a transport failure before the stream is returned as is", function()
    local transport = stub.stream_transport({
      fail = require("distilled.errors").new("TimeoutError", { message = "slow" }),
    })
    local client = client_for("aws.bedrock_runtime", transport)
    t.fails_with("TimeoutError", stub.open(client, "converse_stream", CONVERSE))
  end)

  t.it("a required input member is checked before anything is sent", function()
    local transport, log = stub.stream_transport({ status = 200, body = "" })
    local client = client_for("aws.bedrock_runtime", transport)
    local s, err = stub.open(client, "converse_stream", { messages = json.array({}) })
    t.eq(s, nil)
    t.eq(err.tag, "ParseError")
    t.eq(#log.requests, 0)
  end)

  t.it("strict validation fails an event that does not fit its schema", function()
    local transport = stub.stream_transport({
      status = 200,
      body = event("messageStart", '{"role":5}'),
    })
    local client = client_for("aws.bedrock_runtime", transport, { validation = "strict" })
    local s = ok(stub.open(client, "converse_stream", CONVERSE))
    local item, err = stub.next(s)
    t.eq(item, nil)
    t.eq(err.tag, "ParseError")
    t.match(err.message, "^Event messageStart does not match its schema")
    -- lenient keeps the value as read
    local lenient = client_for(
      "aws.bedrock_runtime",
      (stub.stream_transport({ status = 200, body = event("messageStart", '{"role":5}') }))
    )
    local item2 = ok(stub.next(ok(stub.open(lenient, "converse_stream", CONVERSE))))
    t.eq(item2.messageStart.role, 5)
  end)

  t.it("the stream ends after an error and close() is idempotent", function()
    local transport, log = stub.stream_transport({
      status = 200,
      body = ok(
        es.encode_event({
          kind = "error",
          error_code = "ThrottlingException",
          error_message = "slow",
        })
      ) .. event("messageStop", '{"stopReason":"end_turn"}'),
    })
    local client = client_for("aws.bedrock_runtime", transport)
    local s = ok(stub.open(client, "converse_stream", CONVERSE))
    local item, err = stub.next(s)
    t.eq(item, nil)
    t.eq(err.tag, "ThrottlingException")
    t.eq(err.message, "slow")
    t.truthy(log.readers[1].closed, "the reader is closed when the stream ends")
    local again, err2 = stub.next(s)
    t.eq(again, nil)
    t.eq(err2, nil)
    s:close()
    s:close()
  end)

  t.it("an unmodeled error code is UnknownAwsError with the code", function()
    local transport = stub.stream_transport({
      status = 200,
      body = ok(es.encode_event({ kind = "error", error_code = "Brand.New", error_message = "?" })),
    })
    local client = client_for("aws.bedrock_runtime", transport)
    local _, err = stub.next(ok(stub.open(client, "converse_stream", CONVERSE)))
    t.eq(err.tag, "UnknownAwsError")
    t.eq(err.code, "Brand.New")
  end)

  t.it("a sensitive event member is a secret, and never in the error message", function()
    local transport = stub.stream_transport({
      status = 200,
      body = event("chunk", '{"bytes":"c2VjcmV0IQ=="}'),
    })
    local client = client_for("aws.bedrock_runtime", transport)
    local s =
      ok(stub.open(client, "invoke_model_with_response_stream", { modelId = "m", body = "{}" }))
    local item = ok(stub.next(s))
    t.truthy(secret.is(item.chunk) or secret.is(item.chunk.bytes), "a secret")
    t.eq(secret.unwrap_deep(item.chunk).bytes, "secret!")
    t.no_match(tostring(item.chunk), "secret!", true)
  end)

  t.it("awsJson initial-response fills stream.output and is not an event", function()
    local transport = stub.stream_transport({
      status = 200,
      body = event("initial-response", '{"Unmodeled":1}') .. event(
        "SubscribeToShardEvent",
        '{"Records":[],"ContinuationSequenceNumber":"9","MillisBehindLatest":3}'
      ),
    })
    local client = client_for("aws.kinesis", transport)
    local s = ok(stub.open(client, "subscribe_to_shard", {
      ConsumerARN = "arn:aws:kinesis:us-east-1:123456789012:stream/s/consumer/c:1",
      ShardId = "shardId-000000000000",
      StartingPosition = { Type = "LATEST" },
    }))
    local item = ok(stub.next(s))
    t.eq(item.SubscribeToShardEvent.ContinuationSequenceNumber, "9")
    t.eq(item.SubscribeToShardEvent.MillisBehindLatest, 3)
    t.eq(stub.next(s), nil)
  end)
end)

t.describe("aws event stream operations: the input side", function()
  local INPUT = { LanguageCode = "en-US", MediaSampleRateHertz = 16000, MediaEncoding = "pcm" }

  local function open(reply)
    local transport, log = stub.duplex_transport(reply or { status = 200, body = "" })
    local client = client_for("aws.transcribe_streaming", transport)
    return ok(stub.open(client, "start_stream_transcription", INPUT)), log
  end

  t.it("refuses unknown and malformed events without breaking the stream", function()
    local s, log = open()
    t.fails_with("InvalidInput", s:send({ VideoEvent = {} }))
    t.fails_with("InvalidInput", s:send({ AudioEvent = {}, ConfigurationEvent = {} }))
    t.fails_with("InvalidInput", s:send("audio"))
    t.fails_with("ParseError", s:send({ AudioEvent = { AudioChunk = 5 } }))
    t.fails_with("ParseError", s:send({ ConfigurationEvent = { ChannelDefinitions = "x" } }))
    t.eq(#log.written, 0)
    t.truthy(s:send({ AudioEvent = { AudioChunk = "\0\1" } }))
    t.eq(#log.written, 1)
  end)

  t.it("the tagged form { _tag = ... } is accepted, as in Distilled", function()
    local s, log = open()
    t.truthy(s:send({ _tag = "AudioEvent", AudioChunk = "abc" }))
    local inner = ok(es.decode_message(ok(es.decode_message(log.written[1])).payload))
    t.eq(es.string_header(inner.headers, ":event-type"), "AudioEvent")
    t.eq(es.string_header(inner.headers, ":content-type"), "application/octet-stream")
    t.eq(inner.payload, "abc")
  end)

  t.it("send after close_input fails; close_input twice sends one end frame", function()
    local s, log = open()
    t.truthy(s:close_input())
    t.truthy(s:close_input())
    t.eq(#log.written, 1)
    t.fails_with("SdkError", s:send({ AudioEvent = { AudioChunk = "x" } }))
  end)

  t.it("a non-2xx response is read whole and decoded as the operation's error", function()
    local s = open({
      status = 400,
      headers = { ["x-amzn-errortype"] = "BadRequestException" },
      body = '{"Message":"bad audio"}',
    })
    t.truthy(s:send({ AudioEvent = { AudioChunk = "x" } }))
    local item, err = stub.next(s)
    t.eq(item, nil)
    t.eq(err.tag, "BadRequestException")
    t.eq(err.message, "bad audio")
    t.eq(stub.next(s), nil)
  end)

  t.it("an exception event ends the stream with the modeled class", function()
    local s = open({
      status = 200,
      body = ok(es.encode_event({
        kind = "exception",
        exception_type = "LimitExceededException",
        content_type = "application/json",
        payload = '{"Message":"too many"}',
      })),
    })
    local _, err = stub.next(s)
    t.eq(err.tag, "LimitExceededException")
    t.eq(err.message, "too many")
  end)
end)
