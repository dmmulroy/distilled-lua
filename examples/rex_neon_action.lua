-- A Rex configuration snippet (docs/rex.md): the vendored Neon client in two actions,
-- with the Rex host, a deadline under Rex's 30-second action limit, and operation
-- tracing to a file. Paste the body into ~/.config/rex/init.lua; here it runs through
-- `rex do` against the fixture server, with the vendored tree in /tmp/dlv/vendor:
--
--   lua bin/distilled-lua vendor --out /tmp/dlv/vendor
--   lua bin/distilled-lua generate --model models/neon.json --provider providers/neon.lua \
--     --out /tmp/dlv/vendor/neon
--   verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
--     DISTILLED_VENDOR=/tmp/dlv/vendor NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon \
--     rex do examples/rex_neon_action.lua --action neon_projects'
--   (and --action neon_project project_id=missing for the failure)
local home = os.getenv("HOME")
local vendor = os.getenv("DISTILLED_VENDOR") or (home .. "/.config/rex/vendor")
package.path = vendor .. "/?.lua;" .. vendor .. "/?/init.lua;" .. package.path

local distilled = require("distilled")
local Neon = require("neon")

-- Built once when the configuration loads. The key is read from the environment of the
-- Rex *server* (or use api_key = require("distilled.credentials").from_file(path)).
local neon = Neon.new({
  host = require("distilled.host.rex")(),
  deadline_s = 20, -- retries and their sleeps stop before Rex's 30 s action limit
  tracing = {
    level = "operation",
    file = (os.getenv("DISTILLED_TRACE_DIR") or "/tmp") .. "/neon-traces.jsonl",
    max_bytes = 1000000,
  },
})

rex.action({
  name = "neon_projects",
  title = "Neon: list projects",
  run = function()
    -- distilled.check turns nil, err into a plain error string, which is what Rex shows
    local projects = distilled.check(neon:list_projects_items({ limit = 2 }):collect(20))
    local names = {}
    for i, p in ipairs(projects) do
      names[i] = p.name
    end
    return names
  end,
})

rex.action({
  name = "neon_project",
  title = "Neon: show a project",
  args = { project_id = "string" },
  run = function(_, args)
    local res = distilled.check(neon:get_project({ project_id = args.project_id }))
    return { id = res.project.id, name = res.project.name }
  end,
})
