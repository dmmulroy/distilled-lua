local t = require("spec.harness")
local trace = require("distilled.trace")
local otlp = require("distilled.trace.otlp")
local json = require("distilled.json")
local fake = require("verify.lib.trace_fake_host")

local function one_span()
  local host = fake.new({ epoch = 1700000000, seed = 5 })
  local mem = trace.exporters.memory()
  local tracer = trace.new({ host = host, exporter = mem, level = "debug" })
  tracer:with(
    "op",
    { kind = "client", attributes = { s = "x", i = 429, d = 1.5, b = true } },
    function(op)
      op:set("l", { "a", 2, false })
      op:set("empty", json.array({}))
      host.advance(0.001)
      op:event("retry", { reason = "TooManyRequests" })
      tracer:with("child", {}, function() end)
      return nil, require("distilled.errors").new("TooManyRequests", { message = "slow down" })
    end
  )
  tracer:flush()
  return mem.spans
end

t.describe("otlp.encode", function()
  t.it("produces the ExportTraceServiceRequest shape", function()
    local spans = one_span()
    local doc = otlp.encode(spans, { service_name = "neon" })
    t.eq(#doc.resourceSpans, 1)
    local rs = doc.resourceSpans[1]
    t.same(rs.resource.attributes, { { key = "service.name", value = { stringValue = "neon" } } })
    t.eq(#rs.scopeSpans, 1)
    t.same(rs.scopeSpans[1].scope, { name = "distilled-lua", version = otlp.SCOPE_VERSION })
    local list = rs.scopeSpans[1].spans
    t.eq(#list, 2)
    local op, child = list[1], list[2]
    t.eq(op.traceId, spans[1].trace_id)
    t.eq(op.spanId, spans[1].span_id)
    t.eq(op.parentSpanId, nil) -- root: field omitted
    t.eq(child.parentSpanId, op.spanId)
    t.eq(op.name, "op")
    t.eq(op.kind, 3) -- SPAN_KIND_CLIENT
    t.eq(child.kind, 1) -- SPAN_KIND_INTERNAL
    t.eq(op.startTimeUnixNano, "1700000000000000000")
    t.eq(op.endTimeUnixNano, "1700000000001000000")
    t.eq(type(op.startTimeUnixNano), "string")
    t.same(op.status, { code = 2, message = "slow down" }) -- STATUS_CODE_ERROR
    t.same(child.status, { code = 0 }) -- STATUS_CODE_UNSET
    t.same(op.events, {
      {
        name = "retry",
        timeUnixNano = "1700000000001000000",
        attributes = { { key = "reason", value = { stringValue = "TooManyRequests" } } },
      },
    })
  end)

  t.it("encodes attribute values as AnyValue, keys sorted", function()
    local doc = otlp.encode(one_span())
    local attrs = doc.resourceSpans[1].scopeSpans[1].spans[1].attributes
    t.same(attrs, {
      { key = "b", value = { boolValue = true } },
      { key = "d", value = { doubleValue = 1.5 } },
      { key = "empty", value = { arrayValue = { values = {} } } },
      { key = "error.type", value = { stringValue = "TooManyRequests" } },
      { key = "i", value = { intValue = "429" } },
      {
        key = "l",
        value = {
          arrayValue = {
            values = { { stringValue = "a" }, { intValue = "2" }, { boolValue = false } },
          },
        },
      },
      { key = "s", value = { stringValue = "x" } },
    })
  end)

  t.it(
    "uses the proto3 JSON names for doubles JSON cannot carry, intValue only below 2^53",
    function()
      t.same(otlp.any_value(0 / 0), { doubleValue = "NaN" })
      t.same(otlp.any_value(1 / 0), { doubleValue = "Infinity" })
      t.same(otlp.any_value(-1 / 0), { doubleValue = "-Infinity" })
      t.same(otlp.any_value(-7), { intValue = "-7" })
      t.same(otlp.any_value(2 ^ 53), { doubleValue = 2 ^ 53 })
      t.same(otlp.any_value(9007199254740991), { intValue = "9007199254740991" })
    end
  )

  t.it("encodes to one JSON line that decodes as JSON, arrays included", function()
    local line = otlp.encode_line(one_span(), { service_name = "neon" })
    t.no_match(line, "\n", true)
    local back = json.decode(line)
    t.eq(back.resourceSpans[1].scopeSpans[1].spans[1].kind, 3)
    t.match(line, '"values":[]', true)
    t.match(line, '"events":[]', true) -- the child has no events: an array, not {}
    t.match(line, '"startTimeUnixNano":"1700000000000000000"', true)
  end)

  t.it("defaults the service name", function()
    local doc = otlp.encode({})
    t.eq(doc.resourceSpans[1].resource.attributes[1].value.stringValue, "unknown_service")
    t.match(otlp.encode_line({}), '"spans":[]', true)
  end)
end)

t.describe("otlp.decode", function()
  t.it("round-trips spans", function()
    local spans = one_span()
    local back = otlp.decode(otlp.encode_line(spans, { service_name = "neon" }))
    t.eq(#back, 2)
    for i, s in ipairs(spans) do
      local b = back[i]
      t.eq(b.service_name, "neon")
      b.service_name = nil
      t.same(b, s)
    end
  end)

  t.it("reads upper-case hex ids and the special doubles", function()
    local text =
      [[{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"5B8EFFF798038103D269B633813FC60C",
      "spanId":"EEE19B7EC3C1B174","name":"x","kind":2,"startTimeUnixNano":"1544712660000000000",
      "endTimeUnixNano":"1544712661000000000","attributes":[{"key":"n","value":{"doubleValue":"NaN"}},
      {"key":"big","value":{"intValue":"12345678901"}}]}]}]}]}]]
    local spans = otlp.decode(text)
    t.eq(spans[1].trace_id, "5b8efff798038103d269b633813fc60c")
    t.eq(spans[1].kind, "server")
    t.eq(spans[1].status.code, "unset")
    t.truthy(spans[1].attributes.n ~= spans[1].attributes.n)
    t.eq(spans[1].attributes.big, 12345678901)
    t.eq(trace.ns_diff_ms(spans[1].start_ns, spans[1].end_ns), 1000)
  end)

  t.it("fails with ParseError on bad input, naming the line", function()
    t.fails_with("ParseError", otlp.decode("{"))
    t.fails_with("ParseError", otlp.decode("3")) -- valid JSON, not an object
    local e = t.fails_with("ParseError", otlp.decode_lines('{"resourceSpans":[]}\n\n{oops'))
    t.match(e.message, "line 2", true)
    t.same(otlp.decode_lines(""), {})
  end)
end)
