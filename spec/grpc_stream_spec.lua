-- Incremental gRPC server streams (task 30): distilled.stream.grpc frame decoding on a
-- reader, and protocol.grpc's stream entry point: items as each frame arrives, statuses
-- from HTTP trailers, gRPC-Web trailer frames and trailers-only replies, mid-stream
-- errors, truncated and compressed frames, close(). Cases follow streamReply in
-- core/src/protocol-grpc.ts and core/test/protocol-grpc.test.ts.
local t = require("spec.harness")
local errors = require("distilled.errors")
local S = require("distilled.schema")
local secret = require("distilled.secret")
local grpc = require("distilled.protocol.grpc")
local frames = require("distilled.stream.grpc")
local pb = require("distilled.protobuf")
local testing = require("distilled.testing")
local stub = require("spec.grpc_stream_stub")

local D = {
  messages = {
    ["t.WatchRequest"] = { { 1, "thingId", "string" } },
    ["t.Thing"] = {
      { 1, "thingId", "string" },
      { 2, "size", "uint64" },
      { 3, "secretToken", "string" },
    },
  },
  enums = {},
  methods = {
    ["/t.Things/Watch"] = { "t.WatchRequest", "t.Thing", 1 },
  },
}

local function service()
  local shapes = {}
  shapes.WatchRequest = S.struct({
    name = "WatchRequest",
    members = { S.member({ name = "thingId", schema = S.string }) },
  })
  shapes.Thing = S.struct({
    name = "Thing",
    members = {
      S.member({ name = "thingId", schema = S.string }),
      S.member({ name = "size", schema = S.string }),
      S.member({ name = "secretToken", schema = S.string, sensitive = true }),
    },
  })
  shapes.WatchStream = S.struct({
    name = "WatchStream",
    members = {
      S.member({ name = "items", schema = S.list(S.ref("Thing")), required = true }),
    },
  })
  return {
    name = "things",
    shapes = shapes,
    errors = {
      ThingNotFound = errors.define({
        tag = "ThingNotFound",
        categories = { "NotFoundError" },
        matchers = { { code = 5 } },
      }),
    },
    ops = {
      watch = {
        name = "Watch",
        method = "POST",
        uri = "/t.Things/Watch",
        code = 200,
        input = S.ref("WatchRequest"),
        output = S.ref("WatchStream"),
        errors = { "ThingNotFound" },
        stream = { framing = "grpc" },
      },
    },
  }
end

local SERVICE = service()

local function protocol(web)
  return grpc.new({
    descriptors = D,
    web = web,
    base_url = "https://things.test",
    unknown_tag = "UnknownThingsError",
    parse_tag = "ThingsParseError",
  })
end

local function thing(value)
  return pb.frame(assert(pb.encode(D, "t.Thing", value)))
end

local function web_trailer(text)
  return pb.frame(text, 128)
end

-- runs protocol.stream against one scripted streamed reply
local function open(reply, opts)
  opts = opts or {}
  local tr = stub.transport({ reply })
  local ctx = {
    service = SERVICE,
    host = testing.host({ transport = tr }),
  }
  local parts, err, meta = protocol(opts.web).stream(ctx, SERVICE.ops.watch, { thingId = "x" })
  return parts, err, meta, tr
end

-- every item until the end or an error: items, err
local function drain(parts)
  local items = {}
  while true do
    local item, err = parts.next()
    if item == nil then
      return items, err
    end
    items[#items + 1] = item
  end
end

local GRPC = { ["content-type"] = "application/grpc" }
local WEB = { ["content-type"] = "application/grpc-web+proto" }

t.describe("stream.grpc frames", function()
  t.it("splits frames across any chunk boundary", function()
    local body = thing({ thingId = "a" })
      .. thing({ thingId = "bb" })
      .. web_trailer("grpc-status: 0\r\n")
    for size = 1, 7 do
      local chunks = {}
      for i = 1, #body, size do
        chunks[#chunks + 1] = string.sub(body, i, i + size - 1)
      end
      local dec = frames.new(stub.reader(chunks))
      local a = assert(dec:next())
      local b = assert(dec:next())
      t.eq(pb.decode(D, "t.Thing", a).thingId, "a")
      t.eq(pb.decode(D, "t.Thing", b).thingId, "bb")
      local e, err = dec:next()
      t.eq(e, nil)
      t.eq(err, nil)
      t.eq(dec.trailers["grpc-status"], "0")
      t.eq(dec.rest, 0)
      t.eq((dec:next()), nil)
    end
  end)

  t.it("reports an incomplete last frame as rest, and refuses compressed frames", function()
    local body = thing({ thingId = "a" })
    local dec = frames.new(stub.reader({ string.sub(body, 1, 3) }))
    t.eq((dec:next()), nil)
    t.eq(dec.rest, 3) -- every byte of the incomplete frame
    t.truthy(dec.saw_body)
    dec = frames.new(stub.reader({ string.sub(body, 1, #body - 1) }))
    t.eq((dec:next()), nil)
    t.eq(dec.rest, #body - 1)
    dec = frames.new(stub.reader({}))
    t.eq((dec:next()), nil)
    t.eq(dec.rest, 0)
    t.eq(dec.saw_body, false)
    dec = frames.new(stub.reader({ pb.frame("x", 1) }))
    local v, err = dec:next()
    t.fails_with("ParseError", v, err)
    t.match(err.message, "compressed")
  end)

  t.it("passes a reader error through", function()
    local drop = errors.new("TransportError", { message = "connection reset" })
    local dec = frames.new(stub.reader({ thing({ thingId = "a" }), drop }))
    t.truthy(dec:next())
    local v, err = dec:next()
    t.fails_with("TransportError", v, err)
    t.eq((dec:next()), nil)
  end)
end)

t.describe("grpc protocol.stream", function()
  t.it("delivers each message before the next frame is read", function()
    local log = {}
    local reply = {
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "1" }), thing({ thingId = "2" }), thing({ thingId = "3" }) },
      trailers = { ["grpc-status"] = "0" },
      log = log,
    }
    local parts, err, meta, tr = open(reply)
    t.eq(err, nil)
    t.eq(meta.status, 200)
    t.eq(parts.status, 200)
    t.eq(tr.requests[1].headers["content-type"], "application/grpc")
    t.eq(tr.requests[1].url, "https://things.test/t.Things/Watch")
    local first = assert(parts.next())
    t.eq(first.thingId, "1")
    t.same(log, { 1 }) -- frame 2 not yet pulled from the transport
    t.eq(assert(parts.next()).thingId, "2")
    t.same(log, { 1, 2 })
    t.eq(assert(parts.next()).thingId, "3")
    local e, eerr = parts.next()
    t.eq(e, nil)
    t.eq(eerr, nil)
    t.truthy(tr.readers[1].closed)
  end)

  t.it("decodes items through the output schema (sensitive members wrapped)", function()
    local parts = open({
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "s", size = "18446744073709551615", secretToken = "hush" }) },
      trailers = { ["grpc-status"] = "0" },
    })
    local item = assert(parts.next())
    t.eq(item.size, "18446744073709551615")
    t.truthy(secret.is(item.secretToken))
    t.eq(secret.unwrap(item.secretToken), "hush")
  end)

  t.it("ends with the typed error of a non-zero status in the trailers", function()
    local parts = open({
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "1" }) },
      trailers = { ["grpc-status"] = "5", ["grpc-message"] = "no%20such%20thing" },
    })
    local items, err = drain(parts)
    t.eq(#items, 1)
    t.fails_with("ThingNotFound", nil, err)
    t.eq(err.message, "no such thing")
    t.eq(err.code, 5)
  end)

  t.it("reads a gRPC-Web trailer frame mid-body (OK and failing)", function()
    local parts = open({
      status = 200,
      headers = WEB,
      chunks = { thing({ thingId = "1" }) .. web_trailer("grpc-status: 0\r\ngrpc-message: \r\n") },
    }, { web = true })
    local items, err = drain(parts)
    t.eq(#items, 1)
    t.eq(err, nil)
    parts = open({
      status = 200,
      headers = WEB,
      chunks = {
        thing({ thingId = "1" }),
        web_trailer("grpc-status: 14\r\ngrpc-message: busy\r\n"),
      },
    }, { web = true })
    items, err = drain(parts)
    t.eq(#items, 1)
    t.fails_with("ServiceUnavailable", nil, err)
    t.eq(err.message, "busy")
  end)

  t.it("fails a gRPC-Web body that ends without a status (INTERNAL)", function()
    local parts = open(
      { status = 200, headers = WEB, chunks = { thing({ thingId = "1" }) } },
      { web = true }
    )
    local items, err = drain(parts)
    t.eq(#items, 1)
    t.truthy(errors.is(err))
    t.eq(err.code, 13)
    t.match(err.message, "without a grpc-status", true)
  end)

  t.it("returns a trailers-only error before the stream starts", function()
    local parts, err, meta, tr = open({
      status = 200,
      headers = {
        ["content-type"] = "application/grpc",
        ["grpc-status"] = "5",
        ["grpc-message"] = "gone",
      },
      chunks = {},
    })
    t.fails_with("ThingNotFound", parts, err)
    t.eq(err.message, "gone")
    t.eq(meta.status, 200)
    t.truthy(tr.readers[1].closed)
  end)

  t.it("an OK trailers-only reply is an empty stream", function()
    local parts, err = open({
      status = 200,
      headers = { ["content-type"] = "application/grpc", ["grpc-status"] = "0" },
      chunks = {},
    })
    t.eq(err, nil)
    local items, ierr = drain(parts)
    t.eq(#items, 0)
    t.eq(ierr, nil)
  end)

  t.it("a non-gRPC reply fails with the REST classification (whole body read)", function()
    local parts, err, meta, tr = open({
      status = 503,
      headers = { ["content-type"] = "text/plain" },
      chunks = { "upstream ", "down" },
    })
    t.fails_with("ServiceUnavailable", parts, err)
    t.eq(err.message, "upstream down")
    t.eq(meta.status, 503)
    t.truthy(tr.readers[1].closed)
    parts, err =
      open({ status = 200, headers = { ["content-type"] = "text/html" }, chunks = { "<html>" } })
    t.truthy(errors.is(err))
    t.match(err.message, "unexpected content-type", true)
  end)

  t.it("a mid-stream transport drop ends the stream with that error and closes", function()
    local drop = errors.new("TransportError", { message = "connection reset" })
    local parts, _, _, tr = open({
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "1" }), string.sub(thing({ thingId = "2" }), 1, 3), drop },
    })
    local items, err = drain(parts)
    t.eq(#items, 1)
    t.fails_with("TransportError", nil, err)
    t.truthy(tr.readers[1].closed)
    t.eq((parts.next()), nil)
  end)

  t.it("a truncated last frame is INTERNAL once the status is OK; the status wins", function()
    local partial = string.sub(thing({ thingId = "2" }), 1, 6)
    local parts = open({
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "1" }), partial },
      trailers = { ["grpc-status"] = "0" },
    })
    local items, err = drain(parts)
    t.eq(#items, 1)
    t.eq(err.code, 13)
    t.match(err.message, "truncated gRPC frame")
    parts = open({
      status = 200,
      headers = GRPC,
      chunks = { partial },
      trailers = { ["grpc-status"] = "5" },
    })
    items, err = drain(parts)
    t.fails_with("ThingNotFound", nil, err)
  end)

  t.it("a compressed frame is INTERNAL; an undecodable message a parse error", function()
    local parts = open({ status = 200, headers = GRPC, chunks = { pb.frame("zz", 1) } })
    local _, err = drain(parts)
    t.eq(err.code, 13)
    t.match(err.message, "compressed")
    parts = open({ status = 200, headers = GRPC, chunks = { pb.frame("\255\255\255") } })
    _, err = drain(parts)
    t.fails_with("ThingsParseError", nil, err)
    t.match(err.body, "bytes of protobuf")
  end)

  t.it("close() mid-stream reaps the reader once", function()
    local parts, _, _, tr = open({
      status = 200,
      headers = GRPC,
      chunks = { thing({ thingId = "1" }), thing({ thingId = "2" }) },
    })
    t.truthy(parts.next())
    parts.close()
    parts.close()
    t.eq(tr.readers[1].close_count, 1)
  end)

  t.it("refuses a transport without a stream entry point", function()
    local ctx = {
      service = SERVICE,
      host = testing.host({ transport = testing.transport({ responses = {} }) }),
    }
    local parts, err = protocol().stream(ctx, SERVICE.ops.watch, {})
    t.fails_with("ConfigError", parts, err)
    t.match(err.message, "cannot stream")
  end)

  t.it("returns a transport failure before the body as is", function()
    local parts, err = open(errors.new("TimeoutError", { message = "timed out" }))
    t.fails_with("TimeoutError", parts, err)
  end)
end)
