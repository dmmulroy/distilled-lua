-- The golden trace cases: each renders tree.golden() of a simulated, traced call.
-- Shared by verify/lib/trace_golden.lua (writes the files) and spec/trace_tree_spec.lua
-- (compares against them).
local trace = require("distilled.trace")
local tree = require("distilled.trace.tree")
local fake = require("verify.lib.trace_fake_host")
local sim = require("verify.lib.trace_sim")

local cases = {}

local function run(level, statuses, parent)
  local host = fake.new({ epoch = 1700000000, seed = 99 })
  local mem = trace.exporters.memory()
  local tracer = trace.new({ level = level, host = host, exporter = mem, parent = parent })
  sim.get_project(tracer, host, statuses)
  tracer:flush()
  return tree.golden(mem.spans)
end

cases.list = {
  {
    file = "get_project_debug.txt",
    render = function()
      return run("debug")
    end,
  },
  {
    file = "get_project_operation.txt",
    render = function()
      return run("operation")
    end,
  },
  {
    file = "get_project_retry_ok.txt",
    render = function()
      return run("debug", { 429, 200 }, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    end,
  },
}

return cases
