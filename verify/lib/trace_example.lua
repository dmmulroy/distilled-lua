-- Example `dl trace` / `dl expect` script: a simulated Neon.GetProject with three
-- attempts (429, 429, 503), two backoffs and a final failure (verify/lib/trace_sim.lua).
--
--   verify/dl trace verify/lib/trace_example.lua [--level operation] [--runtime rex]
--   verify/dl expect verify/lib/trace_example.lua
local env = require("verify.lib.trace_env")
local sim = require("verify.lib.trace_sim")

local value, err = sim.get_project(env.tracer, env.host)
if value ~= nil or err.tag ~= "ServiceUnavailable" then
  error(
    "simulation: expected nil, ServiceUnavailable, got " .. tostring(value) .. ", " .. tostring(err)
  )
end

-- `dl expect` calls the returned function with expect(spans); `dl trace` ignores it.
return function(e)
  local op = e:span("Neon.GetProject")
  op:failed("ServiceUnavailable")
    :attr("http.response.status_code", 503)
    :attr("distilled.attempts", 3)
  op:event("retry", { reason = "TooManyRequests" })
  e:no_attr_contains(sim.CANARY)
  if env.tracer.level == "debug" then
    op:children("distilled.attempt"):count(3)
    op:children("distilled.retry.backoff"):count(2):attr("reason", "TooManyRequests")
    op:children("distilled.attempt"):nth(1):failed("TooManyRequests")
    e:span("distilled.credentials"):attr("credential", "<redacted>")
  else
    e:count(1)
  end
end
