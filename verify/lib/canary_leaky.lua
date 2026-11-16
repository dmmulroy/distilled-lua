-- A script that leaks on purpose: `verify/dl canary verify/lib/canary_leaky.lua` must fail
-- and name stdout and the ps samples. Proves the canary can see a leak.
local canary = require("verify.lib.canary")
canary.check_env()
local host = canary.host()
local tracer = canary.tracer(host)
tracer:with("leaky", { attributes = { key = canary.key } }, function() end)
tracer:flush()
print("oops: " .. canary.key)
-- the key as a process argument, while a slow request is in flight
if rawget(_G, "rex") then
  rex.exec({ "sh", "-c", "sleep 1; :", "sh", canary.key })
else
  os.execute("sleep 1; : " .. canary.key)
end
host.transport({
  method = "GET",
  url = canary.url .. canary.SLOW_PATH,
  headers = { authorization = "Bearer " .. canary.key },
})
return "leaked"
