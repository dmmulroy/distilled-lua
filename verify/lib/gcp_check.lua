-- dl gen-diff, the GCP step (task 21): every operation of a generated gcp or
-- google_workspace package (its index and the unstable/ index) builds a request through
-- the package's own protocol (distilled.gcp.protocol / .workspace), not only through
-- request.build as gen_check does: reserved expansion of greedy labels, the body rules,
-- the service base URL, the Authorization and X-Goog-User-Project headers.
--
--   lua verify/lib/gcp_check.lua <root> <clients dir> <package>
--   rex do verify/lib/gcp_check.lua root=<root> dir=<clients dir> package=<package>
local rex_api = rawget(_G, "rex")
local args = {}
if rex_api then
  local a = rawget(rex_api, "args") or {}
  args.root, args.dir, args.package = a.root, a.dir, a.package
else
  args.root, args.dir, args.package = arg[1], arg[2], arg[3]
end
assert(args.root and args.dir and args.package, "usage: gcp_check.lua <root> <dir> <package>")

package.path = args.root
  .. "/lua/?.lua;"
  .. args.root
  .. "/lua/?/init.lua;"
  .. args.root
  .. "/?.lua;"
  .. args.dir
  .. "/?.lua;"
  .. args.dir
  .. "/?/init.lua;"
  .. package.path

local compat = require("distilled.compat")
local secret = require("distilled.secret")
local synth = require("verify.lib.gen_input")

local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local failures = {}
local built, total, services = 0, 0, 0
local workspace = args.package == "google_workspace"

local function fail(what)
  if #failures < 50 then
    failures[#failures + 1] = what
  end
end

local host = {
  getenv = function()
    return nil
  end,
  epoch = function()
    return 1700000000
  end,
}
local creds = { access_token = secret("gcp-check-token"), quota_project = "quota-p" }

local function check_service(module)
  local ok, Class = compat.pcall(require, module)
  if not ok or type(Class) ~= "table" then
    fail(module .. ": does not load: " .. tostring(Class))
    return
  end
  local service = require(module .. ".service")
  local protocol = Class.protocol
  if type(protocol) ~= "table" or type(protocol.encode) ~= "function" then
    fail(module .. ": the class has no protocol with encode")
    return
  end
  services = services + 1
  local names = {}
  for name in pairs(service.ops) do
    names[#names + 1] = name
  end
  table.sort(names)
  local ctx = { service = service, host = host }
  for _, name in ipairs(names) do
    local op = service.ops[name]
    total = total + 1
    local input, ierr = synth.input(op, service.shapes)
    if not input then
      fail(module .. "." .. name .. ": cannot synthesize an input: " .. tostring(ierr))
    else
      for inner in string.gmatch(string.match(op.uri, "^[^?]*"), "{([^}]*)}") do
        local key = string.gsub(inner, "%+$", "")
        if input[key] == nil then
          input[key] = "x"
        end
      end
      local req, err = protocol.encode(ctx, op, input, creds)
      local quota = req and req.headers["x-goog-user-project"]
      if not req then
        fail(module .. "." .. name .. ": encode failed: " .. tostring(err))
      elseif req.method ~= op.method then
        fail(module .. "." .. name .. ": method " .. tostring(req.method))
      elseif not string.find(req.url, "^https://[%w.-]+%.googleapis%.com/") then
        fail(module .. "." .. name .. ": url " .. tostring(req.url))
      elseif string.find(req.url, "[{}]") then
        fail(module .. "." .. name .. ": unfilled placeholder in " .. req.url)
      elseif req.headers.authorization ~= "Bearer gcp-check-token" then
        fail(module .. "." .. name .. ": no bearer token")
      elseif (workspace and quota ~= nil) or (not workspace and quota ~= "quota-p") then
        fail(module .. "." .. name .. ": x-goog-user-project is " .. tostring(quota))
      elseif req.body ~= nil and (req.method == "GET" or req.method == "HEAD") then
        fail(module .. "." .. name .. ": a body on " .. req.method)
      elseif req.body ~= nil and req.headers["content-type"] ~= "application/json" then
        fail(module .. "." .. name .. ": body without application/json")
      else
        built = built + 1
      end
    end
  end
end

local function check_index(module)
  local ok, index = compat.pcall(require, module)
  if not ok or type(index) ~= "table" or type(index.services) ~= "table" then
    fail(module .. ": the index does not load: " .. tostring(index))
    return
  end
  for _, name in ipairs(index.services) do
    check_service(module .. "." .. name)
  end
end

check_index(args.package)
local f = io.open(args.dir .. "/" .. args.package .. "/unstable/init.lua", "rb")
if f then
  f:close()
  check_index(args.package .. ".unstable")
end

for _, line in ipairs(failures) do
  print("FAIL " .. line)
end
local summary = string.format(
  "%s gcp-check %s: %d services, %d/%d ops encoded by the package's protocol",
  #failures == 0 and "ok" or "FAIL",
  runtime,
  services,
  built,
  total
)
print(summary)
if #failures > 0 then
  if rex_api then
    error(summary, 0)
  end
  os.exit(1)
end
return summary
