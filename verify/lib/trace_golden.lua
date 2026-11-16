-- Regenerates the golden trace trees in spec/golden/trace/ from verify/lib/trace_sim.lua.
--   lua verify/lib/trace_golden.lua        (run from the repository root)
-- spec/trace_tree_spec.lua compares against these files; review the diff before committing.
package.path = "lua/?.lua;lua/?/init.lua;./?.lua;" .. package.path
local cases = require("verify.lib.trace_golden_cases")

for _, case in ipairs(cases.list) do
  local path = "spec/golden/trace/" .. case.file
  local f = assert(io.open(path, "wb"))
  f:write(case.render())
  f:close()
  print("wrote " .. path)
end
