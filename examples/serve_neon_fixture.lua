-- Scripts a running `dl serve` with Neon-shaped answers under /neon, for the examples in
-- docs/usage.md and docs/rex.md (no network, no real key). Run it with stock Lua inside
-- `verify/dl serve run`, which sets DL_SERVE_URL:
--
--   verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua && <the example>'
--
-- Paths are the Neon API's under the base URL $DL_SERVE_URL/neon.
local root = string.match(debug.getinfo(1, "S").source, "^@?(.*)/examples/[^/]*$") or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. package.path

local serve = require("verify.lib.serve")
local host = require("distilled.host.popen")()
local s = serve.client(host.transport)

local function project(id, name)
  return { project = { id = id, name = name, region_id = "aws-us-east-2", pg_version = 17 } }
end
local function page(ids, cursor)
  local projects = {}
  for i, id in ipairs(ids) do
    projects[i] = { id = id, name = "Project " .. id }
  end
  return { projects = projects, pagination = { cursor = cursor } }
end

s.reset()
-- a listing over two pages
s.script("/neon/projects", {
  { status = 200, json = page({ "quiet-sun", "late-moon" }, "c1") },
  { status = 200, json = page({ "red-star" }, nil) },
}, { repeat_last = false })
-- a project that is busy twice (503, then 429 with Retry-After: 1), then answers
s.script("/neon/projects/quiet-sun", {
  { status = 503, json = { message = "try again" } },
  { status = 429, headers = { ["retry-after"] = "1" }, json = { message = "slow down" } },
  { status = 200, json = project("quiet-sun", "Quiet Sun") },
})
-- a project that does not exist
s.script("/neon/projects/missing", {
  { status = 404, json = { code = "NOT_FOUND", message = "project not found" } },
}, { repeat_last = true })
-- an API key with its secret in the response
s.script("/neon/api_keys", {
  {
    status = 200,
    json = {
      id = 7,
      key = "napi_example_secret",
      name = "ci",
      created_at = "2024-01-01T00:00:00Z",
      created_by = "u1",
    },
  },
})
print("scripted " .. serve.url() .. "/neon")
