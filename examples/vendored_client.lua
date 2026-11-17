-- A vendored Neon client used from a clean directory, with nothing on package.path but
-- the vendor tree. No network: a hand-written transport answers.
--
--   lua bin/distilled-lua vendor --out /tmp/dlv/vendor
--   lua bin/distilled-lua generate --model models/neon/neon.json --provider providers/neon.lua \
--     --out /tmp/dlv/vendor/neon
--   cd /tmp/dlv && lua    <repo>/examples/vendored_client.lua /tmp/dlv/vendor
--   cd /tmp/dlv && luajit <repo>/examples/vendored_client.lua /tmp/dlv/vendor
--   cd /tmp/dlv && rex do <repo>/examples/vendored_client.lua vendor=/tmp/dlv/vendor
local rex = rawget(_G, "rex")
local vendor = rex and rex.args.vendor or arg[1]
assert(vendor, "usage: vendored_client.lua <vendor dir>")
-- only the vendor tree: a module that is not vendored must fail to load
package.path = vendor .. "/?.lua;" .. vendor .. "/?/init.lua"

local distilled = require("distilled")
local json = require("distilled.json")
local Neon = require("neon")

-- a transport is a function(request) -> response | nil, err
local pages = {
  ["/projects"] = '{"projects":[{"id":"a"},{"id":"b"}],"pagination":{"cursor":"c1"}}',
  ["/projects?cursor=c1"] = '{"projects":[{"id":"c"}],"pagination":{"cursor":null}}',
  ["/projects/p1"] = '{"project":{"id":"p1","name":"demo"}}',
}
local seen = {}
local function transport(req)
  local path = string.match(req.url, "^https://[^/]+/api/v2(.*)$")
  seen[#seen + 1] = req.method .. " " .. path
  local body = pages[path]
  if not body then
    return {
      status = 404,
      headers = { ["content-type"] = "application/json" },
      body = '{"message":"no such thing"}',
    }
  end
  return { status = 200, headers = { ["content-type"] = "application/json" }, body = body }
end

local neon = Neon.new({ api_key = "fake-key", transport = transport })

local project = distilled.check(neon:get_project({ project_id = "p1" }))
local ids = {}
for p in neon:list_projects_items({}) do
  ids[#ids + 1] = p.id
end
local _, err = neon:get_project({ project_id = "missing" })

local not_vendored = {}
for _, name in ipairs({ "distilled.testing", "distilled.gen", "verify.lib.serve" }) do
  local ok = pcall(require, name)
  not_vendored[#not_vendored + 1] = name .. "=" .. (ok and "LOADED" or "absent")
end

local report = {
  project = project.project.name,
  items = table.concat(ids, ","),
  error = tostring(err),
  categories = err.categories.BadRequestError and "BadRequestError" or "?",
  requests = table.concat(seen, " | "),
  not_vendored = table.concat(not_vendored, " "),
}
local text = json.encode(report)
print(text)
return report
