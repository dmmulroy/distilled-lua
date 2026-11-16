-- Helpers for scripts run by `verify/dl canary` (and usable by any script that needs a
-- host on the current runtime).
--
--   local canary = require("verify.lib.canary")
--   canary.key          -- the fake API key (DL_CANARY_KEY), "sk-CANARY-..."
--   canary.url          -- the fixture server (DL_SERVE_URL)
--   canary.trace_file   -- where debug tracing must go (DL_CANARY_TRACE)
--   canary.host()       -- distilled.host.rex in Rex, else popen_curl + a real sleep
--   canary.tracer()     -- a debug-level tracer writing OTLP/JSON lines to trace_file
--   canary.report(label, value, err)  -- prints a result, or tostring(err), to stdout
--
-- dl canary then searches stdout, stderr, the trace file, temp files and `ps` samples
-- taken during the run for canary.key, and checks that the key did reach the server in
-- an authorization header. So a canary script must send at least one request with the
-- key that is still in flight for a while (canary.SLOW_PATH answers after 1.5 s), print
-- its errors, and trace at debug level.
local canary = {}

canary.key = os.getenv("DL_CANARY_KEY")
canary.url = os.getenv("DL_SERVE_URL")
canary.trace_file = os.getenv("DL_CANARY_TRACE")
canary.SLOW_PATH = "/_dl/slow?delay=1.5"

local REX = rawget(_G, "rex")

function canary.check_env()
  if not canary.key or not canary.url or not canary.trace_file then
    error(
      "canary script: run it with verify/dl canary <script> (DL_CANARY_KEY, DL_SERVE_URL, DL_CANARY_TRACE)",
      0
    )
  end
end

--- canary.host() -> a host for this runtime
function canary.host()
  if REX then
    return require("distilled.host.rex")()
  end
  return {
    transport = require("distilled.transport.popen_curl")(),
    -- stock Lua cannot sleep; a script may shell out (the library never does)
    sleep = function(s)
      if s > 0 then
        local p = io.popen(string.format("sleep %.3f", s))
        p:read("*a")
        p:close()
      end
    end,
    now = function()
      local p = io.popen("date +%s.%N 2>/dev/null || date +%s")
      local v = tonumber(p:read("*a")) or os.time()
      p:close()
      return v
    end,
    epoch = os.time,
  }
end

--- canary.tracer([host]) -> a debug tracer exporting to canary.trace_file
function canary.tracer(host)
  local trace = require("distilled.trace")
  return trace.new({
    level = "debug",
    host = host,
    service_name = "distilled-canary",
    exporter = trace.exporters.file({ path = canary.trace_file }),
  })
end

function canary.report(label, value, err)
  local json = require("distilled.json")
  if value == nil then
    print(label .. ": error: " .. tostring(err))
    if type(err) == "table" then
      -- everything an error carries, as a caller might log it
      local fields = {}
      for k, v in pairs(err) do
        if type(v) ~= "table" then
          fields[#fields + 1] = tostring(k) .. "=" .. tostring(v)
        end
      end
      table.sort(fields)
      print("  " .. table.concat(fields, " "))
      if type(err.body) == "string" then
        print("  body: " .. err.body)
      end
    end
  else
    local text = json.encode(value)
    print(label .. ": " .. tostring(text or value))
  end
end

return canary
