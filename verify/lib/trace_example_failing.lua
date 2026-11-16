-- A `dl expect` script whose assertion fails on purpose (the simulated call makes three
-- attempts, not two): `verify/dl expect verify/lib/trace_example_failing.lua` exits 1.
local env = require("verify.lib.trace_env")
local sim = require("verify.lib.trace_sim")

sim.get_project(env.tracer, env.host)

return function(e)
  e:span("Neon.GetProject"):children("distilled.attempt"):count(2)
end
