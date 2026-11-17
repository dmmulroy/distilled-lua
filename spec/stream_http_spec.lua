-- Streaming over the real hosts (distilled.host.popen on lua/luajit, distilled.host.rex in
-- Rex) against `dl serve` (gated on DL_SERVE_URL: `verify/dl test --http`), task 29:
--   * items are delivered as they arrive: the first item is in hand while the server has
--     sent only the first chunk (its own log says so), for NDJSON (Boat's generated
--     client), SSE and gRPC-Web (hand-made services over rest / grpc);
--   * a connection dropped mid-stream ends the iterator with a TransportError, after the
--     items before it; a stalled stream ends at idle_timeout (TimeoutError);
--   * a 503 before the body is retried, and the retry streams;
--   * close() in the middle of a slow stream returns at once and stops curl.
-- AWS event streams over the same hosts: spec/aws_eventstream_http_spec.lua (through the
-- client's `_stream` methods now).
local t = require("spec.harness")
local serve = require("verify.lib.serve")
local json = require("distilled.json")
local errors = require("distilled.errors")
local S = require("distilled.schema")
local Client = require("distilled.client")
local crypto = require("distilled.crypto")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function ok(v, err)
  if v == nil then
    error(tostring(err), 2)
  end
  return v
end

local NDJSON = { ["Content-Type"] = "application/x-ndjson" }

t.describe("streams over HTTP (dl serve)", function()
  if not serve.url() then
    t.pending("DL_SERVE_URL is not set (run verify/dl test --http)")
    return
  end
  local in_rex = rawget(_G, "rex") ~= nil
  local host = in_rex and require("distilled.host.rex")() or require("distilled.host.popen")()
  local s = serve.client(host.transport)

  local function boat(extra)
    local opts = { api_key = "k", base_url = serve.url(), host = host, retry = "none" }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    return require("boat_dev").new(opts)
  end

  local function streams_for(path)
    local out = {}
    for _, st in ipairs(s.streams()) do
      if st.path == path then
        out[#out + 1] = st
      end
    end
    return out
  end

  t.it("NDJSON: the first item arrives before the server sends the second", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      {
        headers = NDJSON,
        chunk_delay = 1.5,
        chunks = json.array({
          '{"type":"started","commandId":"c1"}\n',
          '{"type":"stdout","data":"one\\n"}\n',
          '{"type":"exit","exitCode":0,"success":true}\n',
        }),
      },
    })
    local st = ok(boat():execute_sandbox_command_stream({ sandboxId = "sb1", command = "ls" }))
    t.eq(st.status, 200)
    local first = ok(st:next())
    t.eq(first.type, "started")
    local log = streams_for("/sandboxes/sb1/commands")
    t.eq(#log, 1)
    t.eq(#log[1].sent, 1, "the server had sent one chunk when the first item was in hand")
    local rest = ok(st:collect())
    t.eq(#rest, 2)
    t.eq(rest[1].data, "one\n")
    t.eq(rest[2].exitCode, 0)
    local req = s.requests()[1]
    t.eq(req.method, "POST")
    t.same(json.decode(req.body), { command = "ls", stream = true })
    t.eq(req.headers["authorization"], "Bearer k")
  end)

  t.it("a drop mid-stream: the items before it, then a TransportError", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      {
        headers = NDJSON,
        drop_after = 1,
        chunks = json.array({ '{"type":"started"}\n', '{"type":"stdout","data":"lost"}\n' }),
      },
    })
    local st = ok(boat():execute_sandbox_command_stream({ sandboxId = "sb1", command = "ls" }))
    local got = {}
    for item, err in st:iter() do
      got[#got + 1] = item or err
    end
    t.eq(#got, 2)
    t.eq(got[1].type, "started")
    t.eq(got[2].tag, "TransportError")
    t.eq(#s.requests(), 1, "no retry after the first item")
  end)

  t.it("a 503 before the body is retried and the retry streams", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      { status = 503, json = { message = "busy" } },
      { headers = NDJSON, chunks = json.array({ '{"type":"started"}\n' }) },
    })
    local st =
      ok(boat({ retry = { max_retries = 2, base_ms = 1 } }):execute_sandbox_command_stream({
        sandboxId = "sb1",
        command = "ls",
      }))
    t.eq(ok(st:next()).type, "started")
    t.eq(st:next(), nil)
    t.eq(#s.requests(), 2)
  end)

  t.it("a typed error (409) is read whole and returned from the call", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      { status = 409, json = { code = "sandbox_not_running", message = "stopped" } },
    })
    local st, err = boat():execute_sandbox_command_stream({ sandboxId = "sb1", command = "ls" })
    t.eq(st, nil)
    t.eq(err.status, 409)
    t.eq(err.message, "stopped")
  end)

  t.it("a stalled stream ends at idle_timeout with a TimeoutError", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      { headers = NDJSON, hang = 20, chunks = json.array({ '{"type":"started"}\n' }) },
    })
    local st = ok(
      boat():execute_sandbox_command_stream(
        { sandboxId = "sb1", command = "ls" },
        { idle_timeout = 1 }
      )
    )
    t.eq(ok(st:next()).type, "started")
    local v, err = st:next()
    t.eq(v, nil)
    t.eq(err.tag, "TransportError")
    t.truthy(errors.has_category(err, "TimeoutError"))
  end)

  t.it("close() in the middle of a slow stream stops it", function()
    s.reset()
    s.script("/sandboxes/sb1/commands", {
      {
        headers = NDJSON,
        chunk_delay = 3,
        chunks = json.array({ '{"type":"started"}\n', '{"type":"exit"}\n' }),
      },
    })
    local st = ok(boat():execute_sandbox_command_stream({ sandboxId = "sb1", command = "ls" }))
    t.eq(ok(st:next()).type, "started")
    st:close()
    t.eq(st:next(), nil)
    t.eq(#streams_for("/sandboxes/sb1/commands")[1].sent, 1)
  end)

  t.it("SSE: events arrive one at a time", function()
    s.reset()
    s.script("/events", {
      {
        headers = { ["Content-Type"] = "text/event-stream" },
        chunk_delay = 1.5,
        chunks = json.array({ ': hi\n\ndata: {"n":1}\n\n', 'event: x\ndata: {"n":2}\n\n' }),
      },
    })
    local shapes = {
      In = S.struct({ name = "In", members = {} }),
      Ev = S.struct({ name = "Ev", members = { S.member({ name = "n", schema = S.number }) } }),
    }
    local Class = Client.define({
      service = {
        name = "sse",
        shapes = shapes,
        errors = {},
        ops = {
          events = {
            name = "Events",
            method = "GET",
            uri = "/events",
            code = 200,
            input = S.ref("In"),
            errors = {},
            stream = { framing = "sse", item = S.ref("Ev") },
          },
        },
      },
      protocol = require("distilled.protocol.rest").new({ base_url = serve.url() }),
    })
    local st = ok(Class.new({ host = host, retry = "none" }):events_stream({}))
    t.eq(ok(st:next()).n, 1)
    t.eq(#streams_for("/events")[1].sent, 1)
    t.eq(ok(st:next()).n, 2)
    t.eq(st:next(), nil)
    t.eq(s.requests()[1].headers["accept"], "text/event-stream, application/json")
  end)

  t.it("gRPC-Web: messages arrive one at a time, the trailer frame ends the stream", function()
    local pb = require("distilled.protobuf")
    local D = {
      messages = {
        ["t.WatchRequest"] = { { 1, "thingId", "string" } },
        ["t.Thing"] = { { 1, "thingId", "string" } },
      },
      enums = {},
      methods = { ["/t.Things/Watch"] = { "t.WatchRequest", "t.Thing", 1 } },
    }
    local function frame(id)
      return crypto.base64.encode(pb.frame(ok(pb.encode(D, "t.Thing", { thingId = id }))))
    end
    s.reset()
    s.script("/t.Things/Watch", {
      {
        headers = { ["Content-Type"] = "application/grpc-web+proto" },
        chunk_delay = 1.5,
        chunks_b64 = json.array({
          frame("a"),
          frame("b"),
          crypto.base64.encode(pb.frame("grpc-status: 0\r\n", 128)),
        }),
      },
    })
    local shapes = {
      WatchRequest = S.struct({
        name = "WatchRequest",
        members = { S.member({ name = "thingId", schema = S.string }) },
      }),
      Thing = S.struct({
        name = "Thing",
        members = { S.member({ name = "thingId", schema = S.string }) },
      }),
      WatchStream = S.struct({
        name = "WatchStream",
        members = { S.member({ name = "items", schema = S.list(S.ref("Thing")) }) },
      }),
    }
    local Class = Client.define({
      service = {
        name = "things",
        shapes = shapes,
        errors = {},
        ops = {
          watch = {
            name = "Watch",
            method = "POST",
            uri = "/t.Things/Watch",
            code = 200,
            input = S.ref("WatchRequest"),
            output = S.ref("WatchStream"),
            errors = {},
            stream = { framing = "grpc", item = S.ref("Thing") },
          },
        },
      },
      protocol = require("distilled.protocol.grpc").new({
        descriptors = D,
        web = true,
        base_url = serve.url(),
        unknown_tag = "UnknownThingsError",
        parse_tag = "ThingsParseError",
      }),
    })
    local st = ok(Class.new({ host = host, retry = "none" }):watch_stream({ thingId = "x" }))
    t.eq(ok(st:next()).thingId, "a")
    t.eq(#streams_for("/t.Things/Watch")[1].sent, 1)
    t.eq(ok(st:next()).thingId, "b")
    local v, err = st:next()
    t.eq(v, nil)
    t.eq(err, nil)
  end)
end)
