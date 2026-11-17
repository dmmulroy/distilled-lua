-- Streaming responses (task 29): the Stream object, ndjson/sse framing, the REST
-- protocol's stream, the client's `<op>_stream` methods (span, retry before the first
-- item, timeouts) and Boat's two NDJSON operations, over a scripted streaming transport.
local t = require("spec.harness")
package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local errors = require("distilled.errors")
local json = require("distilled.json")
local stream_lib = require("distilled.stream")
local testing = require("distilled.testing")
local trace = require("distilled.trace")

local NDJSON = { ["content-type"] = "application/x-ndjson" }

local function boat(transport, extra)
  local opts = {
    api_key = "k-secret",
    base_url = "https://boat.test/api/v1",
    transport = transport,
    sleep = function() end,
  }
  for k, v in pairs(extra or {}) do
    opts[k] = v
  end
  return require("boat_dev").new(opts)
end

local EXEC = { sandboxId = "sb1", command = "echo hi" }

-- value, or a failure naming err
local function ok(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

t.describe("stream: framing", function()
  t.it("ndjson frames skip blank lines and strip CR", function()
    local f = stream_lib.framing("ndjson")(stream_lib.string_reader('{"a":1}\r\n\n  \n{"a":2}'))
    t.eq(f.next(), '{"a":1}')
    t.eq(f.next(), '{"a":2}')
    local v, e = f.next()
    t.eq(v, nil)
    t.eq(e, nil)
  end)

  t.it(
    "ndjson.collect reads a whole NDJSON body as { items } only for that content type",
    function()
      local nd = require("distilled.stream.ndjson")
      t.same(nd.collect('{"a":1}\n{"a":2}\n', "application/x-ndjson; charset=utf-8").json.items, {
        { a = 1 },
        { a = 2 },
      })
      t.eq(nd.collect('{"a":1}', "application/json"), nil)
      t.truthy(nd.collect("{bad\n", "application/x-ndjson").non_json)
    end
  )

  t.it(
    "sse frames: data lines joined, comments, event names, id kept, no-data events dropped",
    function()
      local text =
        ': hello\n\nevent: ping\n\nid: 7\ndata: {"a":\ndata:1}\n\nevent: done\ndata: x\n\ndata: cut'
      local f = stream_lib.framing("sse")(stream_lib.string_reader(text))
      local e1 = f.next()
      t.eq(e1.event, "message")
      t.eq(e1.data, '{"a":\n1}')
      t.eq(e1.id, "7")
      local e2 = f.next()
      t.eq(e2.event, "done")
      t.eq(e2.data, "x")
      t.eq(e2.id, "7")
      local v, e = f.next()
      t.eq(v, nil) -- the unterminated last event is dropped
      t.eq(e, nil)
    end
  )

  t.it("string_reader.read_exact reports a body that ends inside a frame", function()
    local r = stream_lib.string_reader("abc")
    t.eq(r:read_exact(2), "ab")
    local v, err = r:read_exact(2)
    t.eq(v, nil)
    t.eq(err.tag, "TransportError")
    t.eq(err.eof, true)
    t.eq(err.partial, "c")
    local v2, e2 = r:read_exact(1)
    t.eq(v2, nil)
    t.eq(e2, nil)
  end)
end)

t.describe("stream: the Stream object", function()
  local function parts(list, final_err)
    local i = 0
    local p = { status = 200, headers = {}, closed = 0 }
    p.next = function()
      i = i + 1
      if list[i] ~= nil then
        return list[i]
      end
      return nil, final_err
    end
    p.close = function()
      p.closed = p.closed + 1
    end
    return p
  end

  t.it("iter yields items, then false, err once, and the parts are closed once", function()
    local p = parts({ 1, 2 }, errors.new("TransportError", { message = "drop" }))
    local ended
    local s = stream_lib.new(p, {
      on_end = function(err, count, reason)
        ended = { err = err, count = count, reason = reason }
      end,
    })
    local seen, errs = {}, {}
    for item, err in s:iter() do
      if item then
        seen[#seen + 1] = item
      else
        errs[#errs + 1] = err
      end
    end
    t.same(seen, { 1, 2 })
    t.eq(#errs, 1)
    t.eq(errs[1].tag, "TransportError")
    t.eq(s.err.tag, "TransportError")
    t.eq(p.closed, 1)
    t.eq(ended.count, 2)
    t.eq(ended.reason, "error")
    s:close()
    t.eq(p.closed, 1, "close after the end does nothing")
    local v, e = s:next()
    t.eq(v, nil)
    t.eq(e, nil)
  end)

  t.it("close stops early and is idempotent; collect honours a limit", function()
    local p = parts({ 1, 2, 3 })
    local reasons = {}
    local s = stream_lib.new(p, {
      on_end = function(_, _, reason)
        reasons[#reasons + 1] = reason
      end,
    })
    t.same(s:collect(2), { 1, 2 })
    t.eq(p.closed, 1)
    s:close()
    t.same(reasons, { "closed" })
    t.eq(s:next(), nil)
  end)

  t.it("a raising decoder becomes an SdkError and still closes", function()
    local p = parts({})
    p.next = function()
      error("boom")
    end
    local s = stream_lib.new(p)
    local v, err = s:next()
    t.eq(v, nil)
    t.eq(err.tag, "SdkError")
    t.eq(p.closed, 1)
  end)

  t.it("send / close_input without a duplex part is an SdkError", function()
    local s = stream_lib.new(parts({}))
    t.fails_with("SdkError", s:send({}))
    t.fails_with("SdkError", s:close_input())
  end)
end)

t.describe("stream: Boat's NDJSON operations", function()
  t.it("execute_sandbox_command_stream sends stream = true and decodes each frame", function()
    local tr = testing.stream_transport({
      responses = {
        {
          headers = NDJSON,
          chunks = {
            '{"type":"started","commandId":"c1"}\n',
            '{"type":"stdout","data":"hi\\n"}\n',
            '{"type":"exit","exitCode":0,"success":true,"signal":null}\n',
          },
        },
      },
    })
    local s = ok(boat(tr):execute_sandbox_command_stream(EXEC))
    t.eq(s.status, 200)
    local req = tr.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://boat.test/api/v1/sandboxes/sb1/commands")
    t.same(json.decode(req.body), { command = "echo hi", stream = true })
    t.eq(req.headers["accept"], "application/x-ndjson, application/json")
    t.eq(req.headers["authorization"], "Bearer k-secret")
    local items = ok(s:collect())
    t.eq(#items, 3)
    t.eq(items[1].type, "started")
    t.eq(items[1].commandId, "c1")
    t.eq(items[2].data, "hi\n")
    t.eq(items[3].exitCode, 0)
    t.eq(items[3].signal, json.null)
    t.truthy(tr.readers[1].closed, "the reader is closed at the end")
  end)

  t.it("items arrive one at a time: the first is returned before the second is read", function()
    local pulled_at_first
    local reader
    local tr = testing.stream_transport({
      responses = {
        {
          headers = NDJSON,
          chunks = {
            '{"type":"started"}\n',
            function()
              pulled_at_first = pulled_at_first or "second chunk reached before the first item"
            end,
            '{"type":"stdout","data":"x"}\n',
          },
        },
      },
    })
    local s = ok(boat(tr):execute_sandbox_command_stream(EXEC))
    reader = tr.readers[1]
    local first = s:next()
    t.eq(first.type, "started")
    t.eq(pulled_at_first, nil)
    t.eq(reader.pulled, 1)
    local second = s:next()
    t.eq(second.data, "x")
    s:close()
  end)

  t.it("a plain attach_command collects the NDJSON lines into { items }", function()
    local tr = testing.transport({
      responses = {
        {
          headers = NDJSON,
          body = '{"type":"attached","processId":4}\n{"type":"exit","status":"exited","exitCode":0}\n',
        },
      },
    })
    local out = ok(boat(tr):attach_command({ sandboxId = "sb1", processId = 4 }))
    t.eq(#out.items, 2)
    t.eq(out.items[1].processId, 4)
    t.eq(out.items[2].status, "exited")
  end)

  t.it("attach_command_stream: GET with the labels, items of CommandAttachFrame", function()
    local tr = testing.stream_transport({
      responses = {
        { headers = NDJSON, chunks = { '{"type":"attached","processId":4,"stdoutOffset":0}\n' } },
      },
    })
    local s =
      ok(boat(tr):attach_command_stream({ sandboxId = "sb1", processId = 4, stdoutOffset = 10 }))
    t.eq(tr.requests[1].method, "GET")
    t.match(tr.requests[1].url, "/sandboxes/sb1/commands/4/stream%?stdoutOffset=10$")
    t.eq(s:next().processId, 4)
    t.eq(s:next(), nil)
  end)

  t.it("a non-2xx reply is the operation's typed error, the whole body read", function()
    local tr = testing.stream_transport({
      responses = {
        {
          status = 409,
          headers = { ["content-type"] = "application/json" },
          chunks = { '{"error":"sandbox_not_running",', '"message":"stopped"}' },
        },
      },
    })
    local s, err = boat(tr, { retry = "none" }):execute_sandbox_command_stream(EXEC)
    t.eq(s, nil)
    t.eq(err.status, 409)
    t.eq(err.message, "stopped")
    t.truthy(tr.readers[1].closed)
  end)

  t.it("a frame that is not JSON ends the stream with the parse error", function()
    local tr = testing.stream_transport({
      responses = {
        { headers = NDJSON, chunks = { '{"type":"started"}\n', "not json\n", '{"type":"exit"}\n' } },
      },
    })
    local s = ok(boat(tr):execute_sandbox_command_stream(EXEC))
    local got = {}
    for item, err in s:iter() do
      got[#got + 1] = item and item.type or err
    end
    t.eq(got[1], "started")
    t.eq(got[2].tag, "BoatParseError")
    t.match(tostring(got[2].cause), "Invalid JSON frame", true)
    t.eq(#got, 2)
    t.truthy(tr.readers[1].closed)
  end)

  t.it("a drop before the first item is retried; a drop after it ends the stream", function()
    local drop = errors.new("TransportError", { message = "connection reset" })
    local tr = testing.stream_transport({
      responses = {
        { headers = NDJSON, chunks = { drop } },
        { headers = NDJSON, chunks = { '{"type":"started"}\n', drop } },
      },
    })
    local c = boat(tr, { retry = { max_retries = 3, base_ms = 1 } })
    local s = ok(c:execute_sandbox_command_stream(EXEC))
    t.eq(#tr.requests, 2, "the first attempt dropped before any item and was retried")
    t.truthy(tr.readers[1].closed)
    t.eq(s:next().type, "started")
    local v, e = s:next()
    t.eq(v, nil)
    t.eq(e.tag, "TransportError")
    t.eq(#tr.requests, 2, "no retry after the first item")
  end)

  t.it(
    "a transport that cannot stream is a ConfigError; an op without op.stream has no method",
    function()
      local c = boat(testing.transport({ responses = {} }))
      t.fails_with("ConfigError", c:execute_sandbox_command_stream(EXEC))
      t.eq(c.get_sandbox_stream, nil)
    end
  )

  t.it("stream options become the request's max_time and idle_timeout; bad ones raise", function()
    local tr = testing.stream_transport({ responses = { { headers = NDJSON, chunks = {} } } })
    local c = boat(tr)
    local s = ok(c:execute_sandbox_command_stream(EXEC, { timeout = 30, idle_timeout = 5 }))
    t.eq(tr.requests[1].max_time, 30)
    t.eq(tr.requests[1].idle_timeout, 5)
    t.eq(s:next(), nil)
    t.raises(function()
      c:execute_sandbox_command_stream(EXEC, { wait = 1 })
    end, "unknown option wait")
  end)

  t.it("one span covers the stream, ends with the last item and counts the items", function()
    local mem = trace.exporters.memory()
    local tracer = trace.new({ level = "operation", exporter = mem })
    local tr = testing.stream_transport({
      responses = { { headers = NDJSON, chunks = { '{"type":"started"}\n', '{"type":"exit"}\n' } } },
    })
    local c = boat(tr, { tracer = tracer })
    local s = ok(c:execute_sandbox_command_stream(EXEC))
    t.eq(#mem.spans, 0, "the span is open while the stream is")
    t.eq(tracer:current(), nil, "and off the tracer's stack between pulls")
    t.truthy(tr.requests[1].headers["traceparent"])
    t.eq(#s:collect(), 2)
    t.eq(#mem.spans, 1)
    local span = mem.spans[1]
    t.eq(span.name, "Boat.ExecuteSandboxCommand")
    t.eq(span.attributes["distilled.stream.items"], 2)
    t.eq(span.attributes["distilled.stream.end"], "end")
    t.eq(span.attributes["http.response.status_code"], 200)
    t.match(tr.requests[1].headers["traceparent"], span.span_id, true)
  end)

  t.it("the span fails with a mid-stream error and records a close", function()
    local mem = trace.exporters.memory()
    local tracer = trace.new({ level = "operation", exporter = mem })
    local tr = testing.stream_transport({
      responses = {
        {
          headers = NDJSON,
          chunks = { '{"type":"started"}\n', errors.new("TransportError", { message = "x" }) },
        },
        { headers = NDJSON, chunks = { '{"type":"started"}\n', '{"type":"exit"}\n' } },
      },
    })
    local c = boat(tr, { tracer = tracer })
    local s = ok(c:execute_sandbox_command_stream(EXEC))
    s:next()
    local _, err = s:next()
    t.eq(err.tag, "TransportError")
    t.eq(err.trace_id, mem.spans[1].trace_id)
    t.eq(mem.spans[1].status.code, "error")
    local s2 = ok(c:execute_sandbox_command_stream(EXEC))
    s2:next()
    s2:close()
    t.eq(mem.spans[2].attributes["distilled.stream.end"], "closed")
    t.eq(mem.spans[2].attributes["distilled.stream.items"], 1)
  end)

  t.it("a sensitive item member would be a secret: items go through the item decoder", function()
    -- strict validation applies to each frame as to a body
    local tr = testing.stream_transport({
      responses = { { headers = NDJSON, chunks = { '{"type":"started","commandId":5}\n' } } },
    })
    local s = ok(boat(tr, { validation = "strict" }):execute_sandbox_command_stream(EXEC))
    local v, err = s:next()
    t.eq(v, nil)
    t.eq(err.tag, "BoatParseError")
  end)
end)
