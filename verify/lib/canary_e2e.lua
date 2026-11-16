-- The end-to-end canary script: the fixture client (verify/lib/serve.lua) with the fake
-- key as its api_key, debug tracing to DL_CANARY_TRACE, against dl serve: a retried call
-- (500, 500, 200), a paginated listing, a typed error (404), a transport failure, a
-- sensitive output, and a slow call that `ps` samples while curl runs.
--   verify/dl canary verify/lib/canary_e2e.lua
local canary = require("verify.lib.canary")
local serve = require("verify.lib.serve")
local fixtures = require("distilled.testing.fixtures")
canary.check_env()

local host = canary.host()
local s = serve.client(host.transport, canary.url)
local page = fixtures.bodies.page
s.script("/c/projects/p1", {
  { status = 500, json = { message = "boom" } },
  { status = 500, json = { message = "boom" } },
  { status = 200, json = fixtures.bodies.project("p1") },
})
s.script("/c/projects", {
  { status = 200, json = page({ "a", "b" }, "c1") },
  { status = 200, json = page({ "c" }) },
})
s.script("/c/projects/missing", { { status = 404, json = { message = "project not found" } } })
s.script(
  "/c/projects/slow",
  { { status = 200, delay = 1.5, json = fixtures.bodies.project("slow") } }
)
s.script(
  "/c/api_keys",
  { { status = 200, json = fixtures.bodies.api_key("napi_" .. "returned-secret") } }
)

local Fake = serve.fixture_class()
local client = Fake.new({
  api_key = canary.key,
  base_url = canary.url .. "/c",
  host = host,
  tracing = { level = "debug", file = canary.trace_file },
  retry = { base_ms = 10 },
})

canary.report("retried", client:get_project({ project_id = "p1" }))
canary.report("listing", client:list_projects_items({ limit = 2 }):collect())
canary.report("typed error", client:get_project({ project_id = "missing" }))
canary.report("slow", client:get_project({ project_id = "slow" }))
local key, key_err = client:create_api_key({ key_name = "ci" })
canary.report("sensitive output", key and { id = key.id, key = tostring(key.key) }, key_err)
canary.report(
  "refused",
  Fake.new({
    api_key = canary.key,
    base_url = "http://127.0.0.1:1",
    host = host,
    tracing = { level = "debug", file = canary.trace_file },
    retry = "none",
  }):get_project({ project_id = "p1" })
)
client:close()
return "done"
