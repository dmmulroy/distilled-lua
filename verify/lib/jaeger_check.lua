-- `verify/dl jaeger check`: export one trace to Jaeger's OTLP HTTP port through the
-- otlp_http exporter and popen_curl, then poll Jaeger's query API until the trace is
-- there. Stock Lua only (io.popen). Exit 0 when found, 1 otherwise.
local trace = require("distilled.trace")
local json = require("distilled.json")
local transport = require("distilled.transport.popen_curl")()

local OTLP = os.getenv("DL_JAEGER_OTLP") or "http://127.0.0.1:4318"
local QUERY = os.getenv("DL_JAEGER_QUERY") or "http://127.0.0.1:16686"

local tracer = trace.new({
  level = "debug",
  service_name = "distilled-lua-jaeger-check",
  exporter = trace.exporters.otlp_http({ endpoint = OTLP, transport = transport }),
})
local trace_id
tracer:with(
  "JaegerCheck.Export",
  { kind = "client", attributes = { ["rpc.method"] = "Check/Export" } },
  function(span)
    trace_id = span.trace_id
    tracer:with("distilled.attempt", {}, function() end)
  end
)
local ok, err = tracer:flush()
if not ok then
  print("FAIL jaeger: export failed: " .. tostring(err))
  os.exit(1)
end
print("exported trace " .. trace_id .. " to " .. OTLP .. "/v1/traces")

for _ = 1, 40 do
  local res = transport({ method = "GET", url = QUERY .. "/api/traces/" .. trace_id, timeout = 5 })
  if res and res.status == 200 then
    local doc = json.decode(res.body)
    local data = type(doc) == "table" and doc.data
    local first = type(data) == "table" and data[1]
    if first and type(first.spans) == "table" and #first.spans > 0 then
      local names = {}
      for i, s in ipairs(first.spans) do
        names[i] = s.operationName
      end
      table.sort(names)
      print(
        "ok   jaeger: trace "
          .. trace_id
          .. " found, "
          .. #first.spans
          .. " spans: "
          .. table.concat(names, ", ")
      )
      os.exit(0)
    end
  end
  local p = io.popen("sleep 0.25")
  p:read("*a")
  p:close()
end
print("FAIL jaeger: trace " .. trace_id .. " not found in " .. QUERY .. "/api/traces within 10 s")
os.exit(1)
