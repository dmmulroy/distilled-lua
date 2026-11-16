-- dl live: one opt-in call to the real API, with debug tracing (the span tree goes to
-- stderr). Read-only (GET) operations only, unless --write is given. Credentials come
-- from the environment through the provider's options (Neon: NEON_API_KEY).
--
--   lua verify/lib/live.lua <root> <provider> <op> [--write] [key=value ...]
--
-- A value is parsed as JSON when it parses (limit=5 -> 5, ids='["a"]' -> list), otherwise
-- it is a string. Exit codes: 0 ok, 1 the call failed, 2 misuse, 3 skipped (no
-- credentials: the call failed with ConfigError before sending anything).
local root, provider, op_name = arg[1], arg[2], arg[3]
if not (root and provider and op_name) then
  io.stderr:write("usage: dl live <provider> <op> [--write] [key=value ...]\n")
  os.exit(2)
end
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local json = require("distilled.json")
local secret = require("distilled.secret")

local function fail(code, msg)
  io.stderr:write("live: " .. msg .. "\n")
  os.exit(code)
end

local ok_class, Class = pcall(require, provider)
if not ok_class then
  fail(2, "no generated client clients/" .. provider .. ": " .. tostring(Class))
end
local service = require(provider .. ".service")
local op = service.ops[op_name]
if not op then
  fail(2, "no operation " .. op_name .. " in clients/" .. provider)
end

local write = false
local input = json.object({})
for i = 4, #arg do
  local a = arg[i]
  if a == "--write" then
    write = true
  else
    local k, v = string.match(a, "^([%w_]+)=(.*)$")
    if not k then
      fail(2, "argument " .. a .. " is not key=value")
    end
    local decoded, err = json.decode(v)
    if err then
      decoded = v
    end
    input[k] = decoded
  end
end

if op.method ~= "GET" and not write then
  fail(
    2,
    op_name .. " is " .. op.method .. ": dl live only runs GET operations unless --write is given"
  )
end

-- secrets in the output are shown as <redacted> (json.encode refuses them)
local function view(v, depth)
  depth = depth or 0
  if secret.is(v) then
    return "<redacted>"
  end
  if type(v) ~= "table" or v == json.null or depth > 200 then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = view(x, depth + 1)
  end
  return json.is_array(v) and json.array(out) or out
end

local client = Class.new({ host = require("distilled.host.popen")(), tracing = "debug" })
local value, err = client[op_name](client, input)
if err then
  io.stdout:write(tostring(err), "\n")
  if err.tag == "ConfigError" then
    fail(3, "skipped: " .. tostring(err.message) .. " (no live call was made)")
  end
  os.exit(1)
end
io.stdout:write(json.encode(view(value), { indent = true }), "\n")
