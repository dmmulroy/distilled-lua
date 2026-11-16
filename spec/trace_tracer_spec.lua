local t = require("spec.harness")
local trace = require("distilled.trace")
local errors = require("distilled.errors")
local secret = require("distilled.secret")
local json = require("distilled.json")
local fake = require("verify.lib.trace_fake_host")

local function setup(opts)
  opts = opts or {}
  local host = fake.new({ epoch = opts.epoch or 1700000000, seed = opts.seed or 42 })
  local mem = trace.exporters.memory()
  local tracer = trace.new({
    level = opts.level or "debug",
    host = host,
    exporter = opts.exporter or mem,
    service_name = "neon",
    parent = opts.parent,
  })
  return tracer, mem, host
end

local function flushed(tracer, mem)
  t.eq(tracer:flush(), true)
  return mem.spans
end

t.describe("trace ids", function()
  t.it("are lowercase hex of 32 and 16 characters, never all zero", function()
    local tracer = setup()
    for _ = 1, 50 do
      local span = tracer:start("x")
      t.match(span.trace_id, "^" .. string.rep("[0-9a-f]", 32) .. "$")
      t.match(span.span_id, "^" .. string.rep("[0-9a-f]", 16) .. "$")
      span:finish()
    end
  end)

  t.it("never come out all zero, even from a random source that only returns 0", function()
    t.eq(
      trace._hex_id(function()
        return 0
      end, 16),
      "0000000000000001"
    )
    local calls = { n = 0 }
    local id = trace._hex_id(function()
      calls.n = calls.n + 1
      return calls.n > 8 and 0.5 or 0
    end, 16)
    t.eq(id, "8000800080008000")
  end)

  t.it("use 16-bit chunks, so the largest random value is exact", function()
    t.eq(
      trace._hex_id(function()
        return 0.99999999999999989
      end, 16),
      "ffffffffffffffff"
    )
    t.eq(
      trace._hex_id(function()
        return 1.5 -- out of range is clamped, not wrapped
      end, 16),
      "ffffffffffffffff"
    )
  end)

  t.it("are distinct across spans", function()
    local tracer = setup()
    local seen = {}
    for _ = 1, 200 do
      local span = tracer:start("x")
      t.falsy(seen[span.span_id], "duplicate span id")
      seen[span.span_id] = true
      span:finish()
    end
  end)
end)

t.describe("timestamps", function()
  t.it("are exact decimal nanoseconds since the epoch", function()
    local tracer, mem, host = setup({ epoch = 1700000000.25 })
    host.advance(1.5)
    local span = tracer:start("a")
    host.advance(0.000000001 * 7)
    span:finish()
    local s = flushed(tracer, mem)[1]
    t.eq(s.start_ns, "1700000001750000000")
    t.eq(s.end_ns, "1700000001750000007")
  end)

  t.it("carry nanoseconds into seconds", function()
    local tracer, mem, host = setup({ epoch = 1700000000.75 })
    host.advance(0.5)
    tracer:start("a"):finish()
    t.eq(flushed(tracer, mem)[1].start_ns, "1700000001250000000")
  end)

  t.it("past 2^53 nanoseconds stay exact (a float64 would round them)", function()
    -- 2^53 ns is ~104 days; any real epoch is far past it
    local tracer, mem, host = setup({ epoch = 4102444800 }) -- 2100-01-01
    host.advance(0.123456789)
    tracer:start("a"):finish()
    t.eq(flushed(tracer, mem)[1].start_ns, "4102444800123456789")
  end)

  t.it("are monotonic when host.now goes backwards", function()
    local tracer, mem, host = setup()
    host.advance(2)
    local a = tracer:start("a")
    host.clock.t = 1 -- the clock jumps back
    a:finish()
    local s = flushed(tracer, mem)[1]
    t.eq(s.start_ns, s.end_ns)
    t.eq(trace.ns_diff_ms(s.start_ns, s.end_ns), 0)
  end)

  t.it("ns_diff_ms subtracts decimal strings exactly", function()
    local d = trace.ns_diff_ms("1700000000999999999", "1700000001000000001")
    t.truthy(math.abs(d - 0.000002) < 1e-9, d)
    t.eq(trace.ns_diff_ms("1700000000000000000", "1700000002500000000"), 2500)
    t.eq(trace.ns_diff_ms("5", "1000005"), 1)
  end)

  t.it("read host.epoch once, at creation", function()
    local calls = { n = 0 }
    local host = fake.new()
    host.epoch = function()
      calls.n = calls.n + 1
      return 1700000000
    end
    local tracer = trace.new({ host = host })
    tracer:start("a"):finish()
    tracer:start("b"):finish()
    t.eq(calls.n, 1)
  end)
end)

t.describe("spans", function()
  t.it("nest through the tracer's stack", function()
    local tracer, mem = setup()
    local a = tracer:start("a", { kind = "client" })
    t.eq(tracer:current(), a)
    local b = tracer:start("b")
    t.eq(tracer:current(), b)
    b:finish()
    t.eq(tracer:current(), a)
    a:finish()
    t.eq(tracer:current(), nil)
    local spans = flushed(tracer, mem)
    t.eq(#spans, 2)
    t.eq(spans[1].name, "a") -- exported in start order
    t.eq(spans[1].kind, "client")
    t.eq(spans[2].kind, "internal")
    t.eq(spans[2].parent_span_id, spans[1].span_id)
    t.eq(spans[2].trace_id, spans[1].trace_id)
    t.eq(spans[1].parent_span_id, nil)
  end)

  t.it("separate root spans start separate traces", function()
    local tracer, mem = setup()
    tracer:start("a"):finish()
    tracer:start("b"):finish()
    local spans = flushed(tracer, mem)
    t.ne(spans[1].trace_id, spans[2].trace_id)
  end)

  t.it("finish is idempotent and set after finish is ignored", function()
    local tracer, mem = setup()
    local a = tracer:start("a")
    a:finish()
    a:set("late", 1)
    a:event("late")
    a:fail(errors.new("NotFound"))
    a:finish()
    local spans = flushed(tracer, mem)
    t.eq(#spans, 1)
    t.same(spans[1].attributes, {})
    t.eq(spans[1].status.code, "unset")
    t.eq(#spans[1].events, 0)
  end)

  t.it("finishing a parent ends children still open under it", function()
    local tracer, mem, host = setup()
    local a = tracer:start("a")
    local b = tracer:start("b")
    host.advance(1)
    a:finish()
    t.eq(tracer:current(), nil)
    b:finish() -- already ended: no-op
    local spans = flushed(tracer, mem)
    t.eq(#spans, 2)
    t.eq(spans[2].name, "b")
    t.eq(spans[2].end_ns, spans[1].end_ns)
  end)

  t.it("open spans are not exported until they finish", function()
    local tracer, mem = setup()
    local a = tracer:start("a")
    tracer:start("b"):finish()
    t.eq(#flushed(tracer, mem), 1)
    a:finish()
    t.eq(#flushed(tracer, mem), 2)
  end)

  t.it("records events with time and attributes", function()
    local tracer, mem, host = setup({ epoch = 1700000000 })
    local a = tracer:start("a")
    host.advance(0.25)
    a:event("retry", { reason = "TooManyRequests", delay_ms = 200 })
    a:finish()
    local e = flushed(tracer, mem)[1].events[1]
    t.eq(e.name, "retry")
    t.eq(e.time_ns, "1700000000250000000")
    t.same(e.attributes, { reason = "TooManyRequests", delay_ms = 200 })
  end)

  t.it("fail sets status error, message and error.type from the tag", function()
    local tracer, mem = setup()
    local a = tracer:start("a")
    a:fail(errors.new("NotFound", { message = "no such project" }))
    a:finish()
    local b = tracer:start("b")
    b:fail("plain string")
    b:finish()
    local spans = flushed(tracer, mem)
    t.same(spans[1].status, { code = "error", message = "no such project" })
    t.eq(spans[1].attributes["error.type"], "NotFound")
    t.same(spans[2].status, { code = "error", message = "plain string" })
    t.eq(spans[2].attributes["error.type"], "_OTHER")
  end)
end)

t.describe("attribute values", function()
  t.it("keeps strings, numbers, booleans and lists of them", function()
    local tracer, mem = setup()
    local a =
      tracer:start("a", { attributes = { s = "x", n = 1.5, b = false, l = { "a", 2, true } } })
    a:set("i", 200)
    a:set("marked", json.array({}))
    a:finish()
    local attrs = flushed(tracer, mem)[1].attributes
    t.same(attrs, { s = "x", n = 1.5, b = false, l = { "a", 2, true }, i = 200, marked = {} })
  end)

  t.it("records a secret as <redacted>, also inside a list", function()
    local tracer, mem = setup()
    local a = tracer:start("a", { attributes = { key = secret.wrap("sk-CANARY") } })
    a:set("keys", { "public", secret.wrap("sk-CANARY") })
    a:event("e", { k = secret.wrap("sk-CANARY") })
    a:fail(secret.wrap("sk-CANARY"))
    a:finish()
    local s = flushed(tracer, mem)[1]
    t.eq(s.attributes.key, "<redacted>")
    t.same(s.attributes.keys, { "public", "<redacted>" })
    t.eq(s.events[1].attributes.k, "<redacted>")
    t.eq(s.status.message, "<redacted>")
    local text = require("distilled.trace.otlp").encode_line({ s })
    t.no_match(text, "sk-CANARY", true)
  end)

  t.it("converts anything else with tostring", function()
    local tracer, mem = setup()
    local err = errors.new("NotFound", { message = "gone" })
    local a = tracer:start("a")
    a:set("err", err)
    a:set("map", { a = 1 })
    a:set("nested", { { 1 } })
    a:set("fn", print)
    a:finish()
    local attrs = flushed(tracer, mem)[1].attributes
    t.eq(attrs.err, "NotFound: gone")
    t.match(attrs.map, "^table")
    t.eq(type(attrs.nested[1]), "string")
    t.eq(type(attrs.fn), "string")
  end)

  t.it("set(key, nil) removes an attribute; non-string keys are ignored", function()
    local tracer, mem = setup()
    local a = tracer:start("a", { attributes = { x = 1, [1] = "positional" } })
    a:set("x", nil)
    a:set(5, "five")
    a:finish()
    t.same(flushed(tracer, mem)[1].attributes, {})
  end)
end)

t.describe("tracer:with", function()
  t.it("ends the span on a normal return and passes every result through", function()
    local tracer, mem = setup()
    local a, b, c = tracer:with("op", nil, function(span)
      t.eq(span.recording, true)
      return 1, nil, 3
    end)
    t.eq(a, 1)
    t.eq(b, nil)
    t.eq(c, 3)
    local s = flushed(tracer, mem)[1]
    t.eq(s.status.code, "unset")
    t.truthy(s.end_ns)
    t.eq(tracer:current(), nil)
  end)

  t.it("on nil, err marks the span failed and returns nil, err unchanged", function()
    local tracer, mem = setup()
    local err = errors.new("TooManyRequests", { status = 429 })
    local v, e = tracer:with("op", {}, function()
      return nil, err
    end)
    t.eq(v, nil)
    t.eq(e, err) -- same table
    t.eq(e.trace_id, nil) -- not modified
    local s = flushed(tracer, mem)[1]
    t.eq(s.status.code, "error")
    t.eq(s.attributes["error.type"], "TooManyRequests")
    t.eq(tracer:current(), nil)
  end)

  t.it("on a raise marks the span failed, ends it and re-raises the original value", function()
    local tracer, mem = setup()
    local boom = { "a table error" }
    local ok, raised = t.pcall(function()
      tracer:with("op", {}, function()
        tracer:start("left-open") -- a child the raise skips past
        error(boom)
      end)
    end)
    t.eq(ok, false)
    t.eq(raised, boom)
    local ok2, raised2 = t.pcall(function()
      tracer:with("op2", {}, function()
        error("string boom", 0)
      end)
    end)
    t.eq(ok2, false)
    t.eq(raised2, "string boom")
    local spans = flushed(tracer, mem)
    t.eq(#spans, 3)
    t.eq(spans[1].name, "op")
    t.eq(spans[1].status.code, "error")
    t.eq(spans[1].attributes["error.type"], "_OTHER")
    t.eq(spans[2].name, "left-open") -- ended with its parent
    t.eq(spans[2].parent_span_id, spans[1].span_id)
    t.eq(spans[3].status.message, "string boom")
    t.eq(tracer:current(), nil)
  end)

  t.it("closures keep working after a caught raise (gopher-lua upvalue bug)", function()
    local tracer = setup()
    local n = 0
    local function bump()
      n = n + 1
    end
    t.pcall(function()
      tracer:with("op", {}, function()
        error("x")
      end)
    end)
    bump()
    t.eq(n, 1)
  end)

  t.it("closures keep working when a raise passes through nested withs", function()
    local tracer = setup()
    local n = 0
    local function bump()
      n = n + 1
    end
    t.pcall(function()
      tracer:with("op", {}, function()
        tracer:with("ok-child", {}, function() end)
        tracer:with("bad-child", {}, function()
          error("inner")
        end)
      end)
    end)
    bump()
    t.eq(n, 1)
  end)

  t.it("closures keep working after a successful with inside a pcall that catches", function()
    local tracer = setup()
    local n = 0
    local function bump()
      n = n + 1
    end
    t.pcall(function()
      tracer:with("op", {}, function() end)
      error("after")
    end)
    bump()
    t.eq(n, 1)
  end)

  t.it("passes a yield from fn through to the caller's coroutine", function()
    local tracer, mem = setup()
    local co = coroutine.create(function()
      return tracer:with("op", {}, function()
        local got = coroutine.yield("paused")
        return got * 2
      end)
    end)
    local ok1, v1 = coroutine.resume(co)
    t.eq(ok1, true)
    t.eq(v1, "paused")
    local ok2, v2 = coroutine.resume(co, 21)
    t.eq(ok2, true)
    t.eq(v2, 42)
    t.eq(coroutine.status(co), "dead")
    t.eq(#flushed(tracer, mem), 1)
  end)

  t.it("children opened inside with nest under it", function()
    local tracer, mem = setup()
    tracer:with("op", { kind = "client" }, function()
      tracer:with("child", {}, function() end)
    end)
    local spans = flushed(tracer, mem)
    t.eq(spans[2].parent_span_id, spans[1].span_id)
  end)
end)

t.describe("levels", function()
  t.it(
    "operation level drops debug spans; their children attach to the nearest recording ancestor",
    function()
      local tracer, mem = setup({ level = "operation" })
      t.eq(tracer.level, "operation")
      tracer:with("op", { kind = "client" }, function(op)
        local d = tracer:start("debug.step", { debug = true })
        t.eq(d.recording, false)
        t.eq(d, trace.NOOP_SPAN)
        d:set("x", 1)
        d:event("e")
        d:fail("x")
        t.eq(tracer:current(), op)
        tracer:with("debug.inner", { debug = true }, function(span)
          t.eq(span.recording, false)
          tracer:with("child", {}, function() end)
        end)
        d:finish()
      end)
      local spans = flushed(tracer, mem)
      t.eq(#spans, 2)
      t.eq(spans[1].name, "op")
      t.eq(spans[2].name, "child")
      t.eq(spans[2].parent_span_id, spans[1].span_id)
    end
  )

  t.it("a debug span under level operation still passes nil, err through with", function()
    local tracer = setup({ level = "operation" })
    local v, e = tracer:with("d", { debug = true }, function()
      return nil, "e"
    end)
    t.eq(v, nil)
    t.eq(e, "e")
  end)

  t.it("debug level records debug spans", function()
    local tracer, mem = setup({ level = "debug" })
    tracer:with("op", {}, function()
      tracer:with("d", { debug = true }, function() end)
    end)
    t.eq(#flushed(tracer, mem), 2)
  end)

  t.it("rejects an unknown level", function()
    t.raises(function()
      trace.new({ level = "verbose" })
    end, "level must be")
  end)
end)

t.describe("traceparent", function()
  t.it("names the current recording span", function()
    local tracer = setup()
    t.eq(tracer:traceparent(), nil)
    tracer:with("op", {}, function(op)
      t.eq(tracer:traceparent(), "00-" .. op.trace_id .. "-" .. op.span_id .. "-01")
      tracer:with("d", { debug = true }, function(d)
        t.eq(tracer:traceparent(), "00-" .. d.trace_id .. "-" .. d.span_id .. "-01")
      end)
    end)
  end)

  t.it("under level operation names the operation span, not a dropped debug span", function()
    local tracer = setup({ level = "operation" })
    tracer:with("op", {}, function(op)
      tracer:with("attempt", { debug = true }, function()
        t.eq(tracer:traceparent(), "00-" .. op.trace_id .. "-" .. op.span_id .. "-01")
      end)
    end)
  end)

  t.it("an incoming parent continues its trace", function()
    local parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    local tracer, mem = setup({ parent = parent })
    tracer:start("a"):finish()
    tracer:start("b"):finish()
    local spans = flushed(tracer, mem)
    for _, s in ipairs(spans) do
      t.eq(s.trace_id, "4bf92f3577b34da6a3ce929d0e0e4736")
      t.eq(s.parent_span_id, "00f067aa0ba902b7")
    end
  end)

  t.it("a malformed parent is ignored", function()
    local bad = {
      "",
      "garbage",
      "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01", -- uppercase
      "00-00000000000000000000000000000000-00f067aa0ba902b7-01", -- zero trace id
      "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", -- zero span id
      "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", -- version ff
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra", -- 00 has no extra
      "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01", -- short trace id
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1",
    }
    for _, p in ipairs(bad) do
      t.eq(trace.parse_traceparent(p), nil, p)
      local tracer, mem = setup({ parent = p })
      tracer:start("a"):finish()
      local s = flushed(tracer, mem)[1]
      t.eq(s.parent_span_id, nil, p)
      t.ne(s.trace_id, "4bf92f3577b34da6a3ce929d0e0e4736", p)
    end
    t.eq(trace.parse_traceparent(42), nil)
  end)

  t.it("accepts a future version with extra fields", function()
    local p =
      trace.parse_traceparent("01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-what")
    t.eq(p.trace_id, "4bf92f3577b34da6a3ce929d0e0e4736")
  end)
end)

t.describe("flush", function()
  t.it("with nothing finished is true and calls no exporter", function()
    local calls = { n = 0 }
    local tracer = setup({
      exporter = function()
        calls.n = calls.n + 1
        return true
      end,
    })
    t.eq(tracer:flush(), true)
    t.eq(calls.n, 0)
  end)

  t.it("hands spans to every exporter once, with the service name", function()
    local got = {}
    local a = function(spans, meta)
      got[#got + 1] = { #spans, meta.service_name }
      return true
    end
    local host = fake.new()
    local tracer = trace.new({ host = host, exporter = { a, a }, service_name = "neon" })
    tracer:start("x"):finish()
    t.eq(tracer:flush(), true)
    t.eq(tracer:flush(), true)
    t.same(got, { { 1, "neon" }, { 1, "neon" } })
  end)

  t.it("returns an exporter failure without raising; other exporters still run", function()
    local mem = trace.exporters.memory()
    local host = fake.new()
    local tracer = trace.new({
      host = host,
      exporter = {
        function()
          return nil, errors.new("SdkError", { message = "disk full" })
        end,
        function()
          error("exporter blew up")
        end,
        mem,
      },
    })
    local v = tracer:with("op", {}, function()
      return "value"
    end)
    t.eq(v, "value") -- the traced call is unaffected
    local e = t.fails_with("SdkError", tracer:flush())
    t.match(e.message, "disk full", true)
    t.match(e.message, "exporter blew up", true)
    t.eq(#mem.spans, 1)
  end)

  t.it("rejects a bad exporter argument", function()
    t.raises(function()
      trace.new({ exporter = 42 })
    end, "exporter")
  end)
end)

t.describe("trace.noop", function()
  t.it("has every method and records nothing", function()
    local noop = trace.noop
    t.eq(noop.level, "off")
    local span = noop:start("x", { kind = "client" })
    t.eq(span.recording, false)
    span:set("k", "v")
    span:event("e", {})
    span:fail("x")
    span:finish()
    t.eq(noop:current(), nil)
    t.eq(noop:traceparent(), nil)
    t.eq(noop:flush(), true)
  end)

  t.it("with runs fn with the shared span and passes results and raises through", function()
    local s1, s2
    local a, b = trace.noop:with("x", nil, function(span)
      s1 = span
      return nil, "err"
    end)
    trace.noop:with("y", {}, function(span)
      s2 = span
    end)
    t.eq(a, nil)
    t.eq(b, "err")
    t.eq(s1, s2) -- one shared span: nothing allocated per call
    t.eq(s1, trace.NOOP_SPAN)
    t.raises(function()
      trace.noop:with("z", {}, function()
        error("through")
      end)
    end, "through")
  end)

  t.it("cannot be modified by accident", function()
    trace.noop.level = "debug"
    trace.NOOP_SPAN.recording = true
    t.eq(trace.noop.level, "off")
    t.eq(trace.NOOP_SPAN.recording, false)
  end)
end)

t.describe("distilled.trace.noop", function()
  t.it("is the same object as trace.noop, with trace.NOOP_SPAN", function()
    local noop = require("distilled.trace.noop")
    t.eq(trace.noop, noop)
    t.eq(noop.NOOP_SPAN, trace.NOOP_SPAN)
    t.eq(noop:start("x"), trace.NOOP_SPAN)
  end)

  t.it("loads nothing else: tracing off never loads the tracer", function()
    -- unload every distilled.trace* module, load only the noop, then put them back
    local saved = {}
    for name, mod in pairs(package.loaded) do
      if string.find(name, "^distilled%.trace") then
        saved[name] = mod
      end
    end
    for name in pairs(saved) do
      package.loaded[name] = nil
    end
    local before = {}
    for name in pairs(package.loaded) do
      before[name] = true
    end
    local ok, fresh = t.pcall(function()
      return require("distilled.trace.noop")
    end)
    local added = {}
    for name in pairs(package.loaded) do
      if not before[name] then
        added[#added + 1] = name
      end
    end
    for name, mod in pairs(saved) do
      package.loaded[name] = mod
    end
    t.eq(ok, true)
    t.same(added, { "distilled.trace.noop" })
    t.eq(fresh.level, "off")
    local a, b = fresh:with("x", nil, function(span)
      return span.recording, "r"
    end)
    t.eq(a, false)
    t.eq(b, "r")
  end)
end)

t.describe("tracer:attach / tracer:detach", function()
  local function by_name(spans)
    local out = {}
    for _, s in ipairs(spans) do
      out[s.name] = s
    end
    return out
  end

  t.it("a detached span stays open but is not the parent of later spans", function()
    local tracer, mem = setup()
    local outer = tracer:start("outer")
    local long = tracer:start("long")
    t.eq(tracer:detach(long), true)
    t.eq(tracer:current(), outer)
    tracer:start("sibling"):finish()
    t.eq(tracer:attach(long), true)
    t.eq(tracer:current(), long)
    t.eq(tracer:traceparent(), "00-" .. long.trace_id .. "-" .. long.span_id .. "-01")
    tracer:start("child"):finish()
    t.eq(tracer:detach(long), true)
    long:finish()
    outer:finish()
    local s = by_name(flushed(tracer, mem))
    t.eq(s.sibling.parent_span_id, s.outer.span_id)
    t.eq(s.child.parent_span_id, s.long.span_id)
    t.eq(s.long.parent_span_id, s.outer.span_id)
    t.truthy(s.long.end_ns)
  end)

  t.it("only the innermost span can be detached", function()
    local tracer = setup()
    local a = tracer:start("a")
    local b = tracer:start("b")
    t.eq(tracer:detach(a), false)
    t.eq(tracer:current(), b)
    b:finish()
    t.eq(tracer:detach(a), true)
    t.eq(tracer:current(), nil)
    t.eq(tracer:detach(a), false, "not on the stack any more")
    a:finish()
  end)

  t.it("attach refuses a span already on the stack, a finished span and non-spans", function()
    local tracer = setup()
    local a = tracer:start("a")
    t.eq(tracer:attach(a), false)
    a:finish()
    t.eq(tracer:attach(a), false)
    t.eq(tracer:current(), nil)
    t.eq(tracer:attach(trace.NOOP_SPAN), false)
    t.eq(tracer:attach(nil), false)
    t.eq(tracer:detach(trace.NOOP_SPAN), false)
    t.eq(tracer:detach(nil), false)
    t.eq(tracer:current(), nil)
  end)

  t.it("a debug span on an operation-level tracer is the no-op span: both return false", function()
    local tracer = setup({ level = "operation" })
    local d = tracer:start("d", { debug = true })
    t.eq(tracer:detach(d), false)
    t.eq(tracer:attach(d), false)
  end)

  t.it("attaching another tracer's span is misuse", function()
    local one, two = setup(), setup()
    local s = one:start("s")
    one:detach(s)
    t.raises(function()
      two:attach(s)
    end, "belongs to another tracer")
    t.eq(two:current(), nil)
    s:finish()
  end)

  t.it("finishing a detached span buffers it and leaves the stack alone", function()
    local tracer, mem = setup()
    local outer = tracer:start("outer")
    local long = tracer:start("long")
    tracer:detach(long)
    long:finish()
    t.eq(tracer:current(), outer)
    outer:finish()
    t.eq(#flushed(tracer, mem), 2)
  end)

  t.it("an attached span's parent finishing ends it too (the stack stays balanced)", function()
    local tracer, mem = setup()
    local outer = tracer:start("outer")
    local long = tracer:start("long")
    tracer:detach(long)
    tracer:attach(long)
    outer:finish()
    t.eq(tracer:current(), nil)
    t.eq(#flushed(tracer, mem), 2)
  end)

  t.it("trace.noop has both and they do nothing", function()
    t.eq(trace.noop:attach(trace.NOOP_SPAN), false)
    t.eq(trace.noop:detach(trace.NOOP_SPAN), false)
    local noop = require("distilled.trace.noop")
    t.eq(noop:attach({}), false)
    t.eq(noop:detach({}), false)
  end)
end)
