local t = require("spec.harness")
local trace = require("distilled.trace")
local tree = require("distilled.trace.tree")
local fake = require("verify.lib.trace_fake_host")
local cases = require("verify.lib.trace_golden_cases")

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function span(id, parent, start, name, extra)
  local s = {
    trace_id = "t1",
    span_id = id,
    parent_span_id = parent,
    name = name,
    kind = "internal",
    start_ns = start,
    end_ns = start,
    attributes = {},
    events = {},
    status = { code = "unset" },
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

t.describe("tree.render", function()
  t.it("indents children under parents in start order, whatever the list order", function()
    local spans = {
      span("c", "a", "1700000000300000000", "second"),
      span("b", "a", "1700000000200000000", "first"),
      span("d", "b", "1700000000250000000", "grandchild"),
      span("a", nil, "1700000000100000000", "root", { end_ns = "1700000001100000000" }),
    }
    t.eq(
      tree.render(spans),
      "trace t1\n"
        .. "  root 1000.0ms unset\n"
        .. "    first 0.0ms unset\n"
        .. "      grandchild 0.0ms unset\n"
        .. "    second 0.0ms unset\n"
    )
  end)

  t.it("shows kind, status, sorted attributes, quoted strings and arrays", function()
    local s = span("a", nil, "1", "op", {
      kind = "client",
      status = { code = "error", message = 'bad "x"\n' },
      attributes = { z = 1, a = "two words", m = { 1, "b", true }, f = 0.5, e = "" },
    })
    t.eq(
      tree.render({ s }, { durations = false }),
      'trace t1\n  op client ERROR "bad \\"x\\"\\n" a="two words" e="" f=0.5 m=[1,b,true] z=1\n'
    )
  end)

  t.it("places events among children by time", function()
    local s = span("a", nil, "100", "op", {
      events = {
        { name = "early", time_ns = "150", attributes = { k = 1 } },
        { name = "late", time_ns = "400", attributes = {} },
      },
    })
    local spans = { s, span("b", "a", "200", "child") }
    t.eq(
      tree.render(spans, { durations = false }),
      "trace t1\n  op unset\n    @ early k=1\n    child unset\n    @ late\n"
    )
  end)

  t.it("groups separate traces and shows a remote parent", function()
    local a = span("a", "remote", "1", "one")
    local b = span("b", nil, "2", "two", { trace_id = "t2" })
    t.eq(
      tree.render({ b, a }, { durations = false }),
      "trace t1 (parent remote)\n  one unset\ntrace t2\n  two unset\n"
    )
  end)

  t.it("is empty for no spans, and survives a very deep tree", function()
    t.eq(tree.render({}), "")
    local spans = {}
    for i = 1, 400 do
      spans[i] =
        span("s" .. i, i > 1 and ("s" .. (i - 1)) or nil, string.format("%d", 1000 + i), "n" .. i)
    end
    local text = tree.render(spans)
    local _, lines = string.gsub(text, "\n", "")
    t.eq(lines, 401)
  end)
end)

t.describe("tree.golden", function()
  t.it("replaces ids, also inside values, and drops durations", function()
    local host = fake.new({ seed = 11 })
    local mem = trace.exporters.memory()
    local tracer = trace.new({ host = host, exporter = mem })
    tracer:with("op", {}, function(op)
      op:set("sent.traceparent", tracer:traceparent())
      host.advance(1)
      tracer:with("child", {}, function() end)
    end)
    tracer:flush()
    t.eq(
      tree.golden(mem.spans),
      "trace trace-1\n  op unset sent.traceparent=00-trace-1-span-1-01\n    child unset\n"
    )
  end)

  t.it("is the same for two runs with different seeds and clocks", function()
    local function run(seed, epoch)
      local host = fake.new({ seed = seed, epoch = epoch })
      local mem = trace.exporters.memory()
      local tracer = trace.new({ host = host, exporter = mem, level = "debug" })
      require("verify.lib.trace_sim").get_project(tracer, host)
      tracer:flush()
      return tree.golden(mem.spans)
    end
    t.eq(run(1, 1700000000), run(777, 1800000000.5))
  end)

  for _, case in ipairs(cases.list) do
    t.it(
      "matches spec/golden/trace/" .. case.file .. " (regenerate: lua verify/lib/trace_golden.lua)",
      function()
        local expected = read(t.root .. "/spec/golden/trace/" .. case.file)
        t.truthy(expected, "golden file missing")
        t.eq(case.render(), expected)
      end
    )
  end
end)
