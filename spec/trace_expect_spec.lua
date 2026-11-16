local t = require("spec.harness")
local trace = require("distilled.trace")
local expect = require("distilled.testing.expect")
local fake = require("verify.lib.trace_fake_host")
local sim = require("verify.lib.trace_sim")

local function traced(level)
  local host = fake.new({ seed = 8 })
  local mem = trace.exporters.memory()
  local tracer = trace.new({ host = host, exporter = mem, level = level or "debug" })
  sim.get_project(tracer, host)
  tracer:flush()
  return mem
end

t.describe("expect", function()
  t.it("passes on the simulated call and chains", function()
    local mem = traced()
    local e = expect(mem) -- a memory exporter or its .spans
    local op = e:span("Neon.GetProject")
    op:attr("http.response.status_code", 503)
      :attr("rpc.method")
      :attr("distilled.retry.errors", { "TooManyRequests", "TooManyRequests" })
      :failed("ServiceUnavailable")
      :failed()
      :no_attr("http.request.body")
      :event("retry")
      :event("retry", { reason = "TooManyRequests", delay_ms = 400 })
      :count(1)
    op:children("distilled.attempt"):count(3)
    op:children():count(7)
    op:children("distilled.attempt"):nth(1):failed("TooManyRequests")
    op:children("distilled.attempt"):nth(3):failed("ServiceUnavailable")
    op:children("distilled.attempt"):nth(2):children("distilled.transport"):count(1):ok()
    op:children("distilled.retry.backoff"):count(2):attr("reason", "TooManyRequests"):ok()
    e:span("distilled.credentials"):parent():attr("rpc.system.name", "neon-api")
    e:spans("distilled.transport"):count(3)
    e:spans():count(11)
    e:count(11)
    e:no_attr_contains(sim.CANARY)
    t.eq(op:get().name, "Neon.GetProject")
    t.eq(#op:children():list(), 7)
    t.match(op:tree({ durations = false }), "distilled.transport", true)
    expect(mem.spans):count(11)
  end)

  t.it("operation level: one span", function()
    local e = expect(traced("operation"))
    e:count(1)
    e:span("Neon.GetProject"):children():count(0)
  end)

  local function failure(fn)
    local raised = t.raises(fn)
    t.eq(type(raised), "string")
    return raised
  end

  t.it("says which span and what was found", function()
    local e = expect(traced())
    local m = failure(function()
      e:span("Neon.GetProject"):attr("http.response.status_code", 200)
    end)
    t.match(
      m,
      'span "Neon.GetProject": attribute http.response.status_code: expected 200, found 503',
      true
    )
    t.match(m, "found: Neon.GetProject client ERROR", true)
    t.match(m, "trace_expect_spec.lua:", true) -- the caller's line

    m = failure(function()
      e:span("Neon.GetProject"):children("distilled.attempt"):count(2)
    end)
    t.match(
      m,
      'span "Neon.GetProject" > children "distilled.attempt": expected 2 spans, found 3',
      true
    )

    m = failure(function()
      e:span("Neon.Missing")
    end)
    t.match(m, 'expected one span "Neon.Missing", found 0; span names: "Neon.GetProject"', true)

    m = failure(function()
      e:span("distilled.attempt")
    end)
    t.match(m, "found 3", true)

    m = failure(function()
      e:span("Neon.GetProject"):failed("TooManyRequests")
    end)
    t.match(m, "expected error.type TooManyRequests, found ServiceUnavailable", true)

    m = failure(function()
      e:span("distilled.request.build"):failed()
    end)
    t.match(m, "expected a failed span, status is unset", true)

    m = failure(function()
      e:span("Neon.GetProject"):ok()
    end)
    t.match(m, "expected no failure", true)

    m = failure(function()
      e:span("Neon.GetProject"):attr("nope")
    end)
    t.match(m, "attribute nope: expected a value, found nothing", true)

    m = failure(function()
      e:span("Neon.GetProject"):no_attr("rpc.method")
    end)
    t.match(m, "attribute rpc.method: expected none, found Neon/GetProject", true)

    m = failure(function()
      e:span("Neon.GetProject"):event("retry", { reason = "Other" })
    end)
    t.match(m, 'expected event "retry" with those attributes', true)

    m = failure(function()
      e:span("Neon.GetProject"):parent()
    end)
    t.match(m, "has no parent", true)

    m = failure(function()
      e:span("Neon.GetProject"):children("distilled.attempt"):nth(4)
    end)
    t.match(m, "no span #4, the selection has 3", true)

    m = failure(function()
      e:spans("nothing"):attr("x")
    end)
    t.match(m, "no spans to check", true)
  end)

  t.it("no_attr_contains searches names, attributes, events and status messages", function()
    local host = fake.new()
    local mem = trace.exporters.memory()
    local tracer = trace.new({ host = host, exporter = mem })
    local leak = "sk-CANARY-leak"
    tracer:with("op", {}, function(op)
      tracer:with("child", { attributes = { ok = "fine" } }, function(c)
        c:event("e", { header = "Bearer " .. leak })
      end)
      op:set("list", { "a", leak })
    end)
    tracer:with("other", {}, function(s)
      s:fail({ tag = "X", message = "token " .. leak })
    end)
    tracer:flush()
    local e = expect(mem)
    local m = failure(function()
      e:span("child"):no_attr_contains(leak)
    end)
    t.match(m, 'found in event e attribute header of span "child"', true)
    m = failure(function()
      e:span("op"):no_attr_contains(leak) -- includes descendants
    end)
    t.match(m, "sk-CANARY-leak", true)
    m = failure(function()
      e:span("other"):no_attr_contains(leak)
    end)
    t.match(m, "status message", true)
    e:span("child"):no_attr_contains("something-else")
  end)

  t.it("rejects a non-list argument", function()
    t.raises(function()
      expect(42)
    end, "expected a list of spans")
  end)
end)
