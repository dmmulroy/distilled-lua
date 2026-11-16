-- How a `dl trace` / `dl expect` script reaches its tracer.
--
--   local env = require("verify.lib.trace_env")
--   env.tracer           -- the installed tracer (level from --level, default debug)
--   env.host             -- a host on a virtual clock: host.sleep(s) advances time at once
--   env.spans()          -- flush, then every span exported so far (memory exporter)
--   env.expect()         -- distilled.testing.expect over env.spans()
--
-- verify/lib/trace_run.lua calls env.install{ level, file, service_name } before it runs
-- the script; a script run directly (lua my_script.lua) gets a debug-level tracer with a
-- memory exporter on first require.
local trace = require("distilled.trace")
local exporters = require("distilled.trace.exporters")
local expect = require("distilled.testing.expect")

local env = {}

-- Wall-ish clock: os.clock is CPU time in lua/luajit and wall time in gopher-lua; the
-- virtual offset makes sleeps (backoff) show their full length without waiting.
local function make_host()
  local clock = { offset = 0 }
  local host = { sleeps = {} }
  function host.now()
    return os.clock() + clock.offset
  end
  function host.epoch()
    return os.time()
  end
  function host.random()
    return math.random()
  end
  function host.sleep(s)
    host.sleeps[#host.sleeps + 1] = s
    clock.offset = clock.offset + s
  end
  function host.advance(s)
    clock.offset = clock.offset + s
  end
  return host
end

local seeded = { done = false }
local function seed()
  if seeded.done then
    return
  end
  seeded.done = true
  -- LuaJIT starts math.random with a fixed seed; mix in the time so ids differ per run
  math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
end

--- env.install{ level = "debug" | "operation", file = path | nil, service_name } -> env
function env.install(opts)
  opts = opts or {}
  seed()
  env.host = make_host()
  env.memory = exporters.memory()
  local list = { env.memory }
  if opts.file then
    list[#list + 1] = exporters.file({ path = opts.file })
  end
  env.file = opts.file
  env.tracer = trace.new({
    level = opts.level or "debug",
    exporter = list,
    host = env.host,
    service_name = opts.service_name or "distilled-lua-verify",
  })
  return env
end

--- env.flush() -> true | nil, err
function env.flush()
  return env.tracer:flush()
end

--- env.spans() -> every span exported so far (flushes first)
function env.spans()
  env.tracer:flush()
  return env.memory.spans
end

--- env.expect() -> an expect selection over env.spans()
function env.expect()
  return expect(env.spans())
end

env.install()

return env
