-- A Rex action that calls an API through the distilled-lua client, with the Rex host.
-- The "API" is the task 03 fixture service (Neon-shaped) served by `dl serve`, so this
-- runs with no network and no real key:
--
--   verify/dl rex --serve examples/rex_action.lua --action distilled_demo
--   verify/dl rex --serve examples/rex_action.lua --action distilled_demo delay=3
--
-- (`dl rex` runs `rex do` with this repository on LUA_PATH; `--serve` starts a private
-- fixture server and sets DL_SERVE_URL. Nothing under ~/.config/rex is touched.)
--
-- In a real configuration file the client would be built the same way, from a generated
-- provider module instead of serve.fixture_class(), and with a real key read from the
-- server's environment or a file.
local distilled = require("distilled")
local serve = require("verify.lib.serve")
local fixtures = require("distilled.testing.fixtures")

local base = os.getenv("DL_SERVE_URL")
if not base then
  error("examples/rex_action.lua: run it with verify/dl rex --serve (DL_SERVE_URL is not set)", 0)
end

local host = require("distilled.host.rex")()

-- Script the fixture server: a listing over two pages, a project that fails twice
-- before it answers, and a slow project for the blocking measurement.
local s = serve.client(host.transport, base)
local page = fixtures.bodies.page
s.script("/demo/projects", {
  { status = 200, json = page({ "quiet-sun", "late-moon" }, "c1") },
  { status = 200, json = page({ "red-star" }) },
}, { repeat_last = false })
s.script("/demo/projects/quiet-sun", {
  { status = 503, json = { message = "try again" } },
  { status = 500, json = { message = "try again" } },
  { status = 200, json = fixtures.bodies.project("quiet-sun", "Quiet Sun") },
})

local Fake = serve.fixture_class()
local client = Fake.new({
  api_key = "sk-example-not-a-real-key",
  base_url = base .. "/demo",
  host = host,
  retry = { deadline_s = 20 }, -- below Rex's 30 s action limit
})

rex.action({
  name = "distilled_demo",
  title = "distilled-lua: list fixture projects",
  args = { delay = "number?" },
  run = function(_, args)
    local started = os.clock()
    if args and args.delay then
      -- a slow request, to see whether it blocks other Rex commands meanwhile
      s.script("/demo/projects/slow", {
        { status = 200, delay = args.delay, json = fixtures.bodies.project("slow") },
      })
      distilled.check(client:get_project({ project_id = "slow" }))
    end
    local projects = distilled.check(client:list_projects_items({ limit = 2 }):collect(20))
    local names = {}
    for i, p in ipairs(projects) do
      names[i] = p.id
    end
    local retried = distilled.check(client:get_project({ project_id = "quiet-sun" }))
    return {
      projects = names,
      retried = retried.project.name,
      seconds = math.floor((os.clock() - started) * 1000 + 0.5) / 1000,
    }
  end,
})
