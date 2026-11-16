-- Writing a transport and a host (docs/usage.md, "The host seam"). Runs anywhere, no
-- network: a transport is just a function from a request table to a response table.
--
--   lua examples/custom_transport.lua
--   luajit examples/custom_transport.lua
--   verify/dl rex examples/custom_transport.lua
local root = string.match(debug.getinfo(1, "S").source, "^@?(.*)/examples/[^/]*$") or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local distilled = require("distilled")
local errors = require("distilled.errors")
local Neon = require("neon")

-- request  = { method, url, headers = { [lowercase name] = value }, body = string|nil, timeout }
-- response = { status, headers = { [lowercase name] = value }, body = string }
-- failure  = nil, err  (an error table, normally tag "TransportError")
local log = {}
local answers = { 503, 200 }
local function transport(req)
  log[#log + 1] = req.method
    .. " "
    .. req.url
    .. " auth="
    .. tostring(req.headers.authorization ~= nil)
  local status = table.remove(answers, 1)
  if not status then
    return nil, errors.new("TransportError", { message = "no more answers" })
  end
  local body = status == 200 and '{"project":{"id":"p1","name":"demo"}}' or '{"message":"busy"}'
  return { status = status, headers = { ["content-type"] = "application/json" }, body = body }
end

-- a host: transport plus a clock; sleep here only records (a real host must wait)
local slept = {}
local now = 0
local host = {
  transport = transport,
  sleep = function(s)
    slept[#slept + 1] = s
    now = now + s
  end,
  now = function()
    return now
  end,
}

-- a secret option may be a function: called when a request needs it, then cached
local neon = Neon.new({
  host = host,
  api_key = function()
    return "key-from-a-vault"
  end,
})

local res = distilled.check(neon:get_project({ project_id = "p1" }))
print("name:", res.project.name)
print("requests:", table.concat(log, " | "))
print("slept:", #slept, "time(s), first", slept[1] and string.format("%.3f s", slept[1]))
local _, err = neon:get_project({ project_id = "p1" })
-- a TransportError has category NetworkError, which the default policy retries (3 tries)
print("after the answers ran out:", tostring(err), "transient:", tostring(errors.is_transient(err)))
print("requests in all:", #log)
return { name = res.project.name, requests = #log }
