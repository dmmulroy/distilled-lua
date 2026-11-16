local t = require("spec.harness")
local trace = require("distilled.trace")
local exporters = require("distilled.trace.exporters")
local otlp = require("distilled.trace.otlp")
local fake = require("verify.lib.trace_fake_host")
local sim = require("verify.lib.trace_sim")

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function lines_of(s)
  local out = {}
  for line in string.gmatch(s or "", "[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

local function traced_call(exporter, level)
  local host = fake.new({ seed = 3 })
  local tracer =
    trace.new({ host = host, exporter = exporter, level = level or "debug", service_name = "neon" })
  sim.get_project(tracer, host)
  return tracer
end

t.describe("exporters.memory", function()
  t.it("accumulates spans across flushes and clears", function()
    local mem = exporters.memory()
    local tracer = traced_call(mem, "operation")
    t.eq(tracer:flush(), true)
    t.eq(#mem.spans, 1)
    sim.get_project(tracer, fake.new())
    tracer:flush()
    t.eq(#mem.spans, 2)
    mem:clear()
    t.eq(#mem.spans, 0)
  end)
end)

t.describe("exporters.file", function()
  t.it("appends one OTLP/JSON request per flush, each a line", function()
    local path = os.tmpname()
    os.remove(path)
    local tracer = traced_call(exporters.file({ path = path }))
    t.eq(tracer:flush(), true)
    sim.get_project(tracer, fake.new())
    t.eq(tracer:flush(), true)
    t.eq(tracer:flush(), true) -- nothing new: no empty line written
    local lines = lines_of(read(path))
    t.eq(#lines, 2)
    for _, line in ipairs(lines) do
      local spans = otlp.decode(line)
      t.eq(#spans, 11)
      t.eq(spans[1].service_name, "neon")
    end
    t.no_match(read(path), sim.CANARY, true)
    t.eq(#otlp.decode_lines(read(path)), 22)
    os.remove(path)
  end)

  t.it("truncates the file before writing once it exceeds max_bytes", function()
    local path = os.tmpname()
    local f = io.open(path, "wb")
    f:write(string.rep("x", 5000), "\n")
    f:close()
    local tracer = traced_call(exporters.file({ path = path, max_bytes = 4000 }), "operation")
    t.eq(tracer:flush(), true)
    local text = read(path)
    t.no_match(text, "xxxx", true) -- the old content is gone
    t.eq(#lines_of(text), 1)
    -- below the limit: appended
    local size = #text
    sim.get_project(tracer, fake.new())
    tracer:flush()
    t.eq(#lines_of(read(path)), 2)
    t.truthy(#read(path) > size)
    os.remove(path)
  end)

  t.it("an unwritable path is an SdkError from flush, never a raise into the call", function()
    local tracer = trace.new({
      host = fake.new(),
      exporter = exporters.file({ path = "/nonexistent-dir/x/trace.jsonl" }),
    })
    local v = tracer:with("op", {}, function()
      return "fine"
    end)
    t.eq(v, "fine")
    local e = t.fails_with("SdkError", tracer:flush())
    t.match(e.message, "cannot open", true)
  end)

  t.it("rejects a missing path at construction", function()
    t.raises(function()
      exporters.file({})
    end, "path")
  end)
end)

t.describe("exporters.console", function()
  t.it("writes the span tree", function()
    local out = {}
    local tracer = traced_call(exporters.console({
      write = function(s)
        out[#out + 1] = s
      end,
    }))
    t.eq(tracer:flush(), true)
    t.eq(#out, 1)
    t.match(out[1], "^trace %x+\n  Neon%.GetProject client 750%.0ms ERROR")
    t.match(out[1], "\n    distilled.attempt 50.0ms", true)
    t.no_match(out[1], sim.CANARY, true)
  end)
end)

t.describe("trace.exporters", function()
  t.it("is the exporters module, loaded on first use", function()
    t.eq(trace.exporters, exporters)
  end)
end)
