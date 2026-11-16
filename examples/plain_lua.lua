-- The generated Neon client in stock Lua or LuaJIT (docs/usage.md). Against the fixture
-- server, with a fake key:
--
--   verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
--     NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon lua examples/plain_lua.lua'
--
-- Against the real API: set NEON_API_KEY and leave NEON_API_BASE_URL unset (and expect
-- different project ids).
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
local Neon = require("neon")

-- api_key and base_url default to NEON_API_KEY and NEON_API_BASE_URL
local neon = Neon.new({ host = require("distilled.host.popen")() })

-- 1. a call: value, or nil and an error table. This one is retried twice (503, then 429
--    with Retry-After: 1) before it succeeds.
local res, err = neon:get_project({ project_id = "quiet-sun" })
if err then
  error(tostring(err), 0)
end
print("project:", res.project.name)

-- 2. errors are values: match on the tag or on a category
local _, e = neon:get_project({ project_id = "missing" })
print("error:", e.tag, e.status, e.code, e.message)
if e.tag == "NotFound" then
  print(
    "  not found (categories: BadRequestError=" .. tostring(e.categories.BadRequestError) .. ")"
  )
end

-- 3. pagination: every item across pages, then check it.err
local it = neon:list_projects_items({ limit = 2 })
for project in it do
  print("item:", project.id)
end
if it.err then
  error(tostring(it.err), 0)
end

-- 4. secrets in responses are wrapped: printing one shows <redacted>
local key = distilled.check(neon:create_api_key({ key_name = "ci" }))
print("api key:", tostring(key.key), "unwrapped length", #distilled.secret.unwrap(key.key))

-- 5. a scoped override: same credentials and budget, no retry, strict validation
local strict = neon:with({ retry = "none", validation = "strict" })
local _, e2 = strict:get_project({ project_id = "missing" })
print("strict, no retry:", tostring(e2))
