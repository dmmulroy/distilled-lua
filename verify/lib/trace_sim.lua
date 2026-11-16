-- A simulated operation, traced by hand, until real clients exist (tasks 04-05):
-- Neon.GetProject with three attempts (429, 429, 503), two backoffs and a final failure.
-- Shared by the tracing specs, the golden trace and verify/lib/trace_example.lua.
--
--   local sim = require("verify.lib.trace_sim")
--   local value, err = sim.get_project(tracer, host)   --> nil, ServiceUnavailable
local errors = require("distilled.errors")
local secret = require("distilled.secret")

local sim = {}

sim.CANARY = "sk-CANARY-0123456789"

sim.STATUSES = { 429, 429, 503 }
sim.DELAYS = { 0.2, 0.4 }

local function attempt(tracer, host, n, status)
  return tracer:with("distilled.attempt", {
    debug = true,
    attributes = { ["distilled.attempt"] = n, ["http.request.resend_count"] = n - 1 },
  }, function(span)
    tracer:with(
      "distilled.transport",
      { debug = true, attributes = { transport = "curl" } },
      function(t)
        host.advance(0.05)
        t:set("http.response.status_code", status)
      end
    )
    span:set("http.response.status_code", status)
    if status < 400 then
      return true
    end
    return nil, errors.new(errors.STATUS_MAP[status] or "UnknownError", { status = status })
  end)
end

--- sim.get_project(tracer, host [, statuses]) -> value | nil, err
function sim.get_project(tracer, host, statuses)
  statuses = statuses or sim.STATUSES
  return tracer:with("Neon.GetProject", {
    kind = "client",
    attributes = {
      ["rpc.system.name"] = "neon-api",
      ["rpc.method"] = "Neon/GetProject",
      ["url.template"] = "/projects/{project_id}",
      ["neon.project_id"] = "proj-quiet-sun",
    },
  }, function(op)
    tracer:with("distilled.credentials", { debug = true }, function(c)
      -- a secret recorded by mistake must come out redacted
      c:set("credential", secret.wrap(sim.CANARY))
    end)
    tracer:with("distilled.request.build", { debug = true }, function() end)
    op:set("http.request.method", "GET")
    op:set("server.address", "console.neon.tech")
    op:set("server.port", 443)
    local retry_errors = {}
    local delay_ms = 0
    local err
    for n = 1, #statuses do
      local _, e = attempt(tracer, host, n, statuses[n])
      op:set("http.response.status_code", statuses[n])
      if not e then
        return { id = "proj-quiet-sun" }
      end
      err = e
      local delay = sim.DELAYS[n]
      if not delay or not e.retryable then
        break
      end
      retry_errors[#retry_errors + 1] = e.tag
      delay_ms = delay_ms + delay * 1000
      op:set("distilled.attempts", n + 1)
      op:set("distilled.retry.errors", retry_errors)
      op:set("distilled.retry.delay_ms", delay_ms)
      op:event("retry", { reason = e.tag, delay_ms = delay * 1000 })
      tracer:with("distilled.retry.backoff", {
        debug = true,
        attributes = { delay_ms = delay * 1000, reason = e.tag },
      }, function()
        host.sleep(delay)
      end)
    end
    return nil, err
  end)
end

return sim
