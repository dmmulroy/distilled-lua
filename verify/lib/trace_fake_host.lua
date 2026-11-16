-- A deterministic host for tracing specs and examples: a fake clock that sleep()
-- advances instantly (recording each wait) and a seeded random source.
--
--   local fake = require("verify.lib.trace_fake_host")
--   local host = fake.new{ epoch = 1700000000.25, seed = 7 }
--   host.sleep(0.2); host.now() --> 0.2; host.sleeps --> { 0.2 }
local fake = {}

-- Park-Miller minimal standard generator: a * x stays below 2^46, exact in float64,
-- and needs no bitwise operators (Lua 5.1 has none).
local M = 2147483647
local A = 16807

function fake.random_source(seed)
  local state = { x = (seed or 1) % M }
  if state.x <= 0 then
    state.x = state.x + M - 1
  end
  return function()
    state.x = (A * state.x) % M
    return (state.x - 1) / (M - 1) -- [0, 1)
  end
end

--- fake.new{ epoch = seconds, now = seconds, seed = n } -> host
-- host.now() starts at opts.now (default 0); host.epoch() is fixed at opts.epoch.
-- State lives in tables (see compat.pcall about gopher-lua upvalues).
function fake.new(opts)
  opts = opts or {}
  local clock = { t = opts.now or 0 }
  local host = { sleeps = {}, clock = clock }
  local epoch = opts.epoch or 1700000000
  host.random = fake.random_source(opts.seed or 1)
  function host.now()
    return clock.t
  end
  function host.epoch()
    return epoch
  end
  function host.sleep(s)
    host.sleeps[#host.sleeps + 1] = s
    clock.t = clock.t + s
  end
  -- move the clock without recording a sleep (time spent "working")
  function host.advance(s)
    clock.t = clock.t + s
  end
  return host
end

return fake
