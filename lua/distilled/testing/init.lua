-- Test seams used by every spec from task 03 on: a scripted transport and a fake host.
-- Library code never requires this module.
--
--   local testing = require("distilled.testing")
--   local tr = testing.transport{ responses = { { status = 500 }, { status = 200, body = { id = 1 } } } }
--   tr(request) -> response | nil, err      -- callable; tr.requests lists what it saw
--
--   local host = testing.host{ now = 0, seed = 1, env = { NEON_API_KEY = "k" },
--                              responses = { ... } }
--   host.sleep(0.5); host.now() == 0.5; host.sleeps == { 0.5 }
--   host.random() -- deterministic for a seed, the same on every runtime
--   host.transport -- the scripted transport (host.requests is its request list)
local json = require("distilled.json")
local errors = require("distilled.errors")
local compat = require("distilled.compat")

local testing = {}

local function copy_headers(h)
  local out = {}
  for k, v in pairs(h or {}) do
    out[k] = v
  end
  return out
end

-- A scripted response: { status = 200, headers = {...}, body = string | table }. A
-- table body is JSON-encoded; header names are lowercased; status defaults to 200.
local function normalize_response(r)
  local headers = {}
  for k, v in pairs(r.headers or {}) do
    headers[string.lower(k)] = v
  end
  local body = r.body
  if type(body) == "table" then
    local text, err = json.encode(body)
    if not text then
      compat.raise("testing.transport: cannot encode a scripted body: " .. tostring(err), 3)
    end
    body = text
    if headers["content-type"] == nil then
      headers["content-type"] = "application/json"
    end
  end
  return { status = r.status or 200, headers = headers, body = body or "" }
end

local Transport = {}
Transport.__index = Transport

--- transport(request) -> response | nil, err
-- A scripted entry is a response table, an error table (returned as nil, err) or a
-- function(request) -> response | nil, err. Running out raises: a test that sends more
-- requests than it scripted is wrong, and must not pass by accident.
function Transport.__call(self, req)
  local n = #self.requests + 1
  self.requests[n] = {
    method = req and req.method,
    url = req and req.url,
    headers = copy_headers(req and req.headers),
    body = req and req.body,
    timeout = req and req.timeout,
  }
  local entry = self.responses[n]
  if entry == nil then
    self.exhausted = true
    error(
      "testing.transport: no scripted response for request #"
        .. n
        .. " ("
        .. tostring(req and req.method)
        .. " "
        .. tostring(req and req.url)
        .. "); "
        .. (n - 1)
        .. " scripted",
      2
    )
  end
  if type(entry) == "function" then
    local res, err = entry(req)
    if res == nil then
      return nil, err
    end
    return normalize_response(res)
  end
  if errors.is(entry) then
    return nil, entry
  end
  return normalize_response(entry)
end

--- transport:remaining() -> how many scripted responses are left
function Transport:remaining()
  return #self.responses - #self.requests
end

--- testing.transport{ responses = { ... } } -> callable transport
function testing.transport(opts)
  opts = opts or {}
  local responses = opts.responses or opts
  if type(responses) ~= "table" then
    compat.raise("testing.transport: responses must be a list", 2)
  end
  return setmetatable({ responses = responses, requests = {}, exhausted = false }, Transport)
end

-- Park-Miller minimal standard generator: products stay below 2^53, so it is exact in
-- doubles and gives the same sequence on lua 5.5, luajit and gopher-lua.
local function make_random(seed)
  local state = { x = (math.floor(seed or 1) % 2147483646) + 1 }
  return function(m, n)
    state.x = (16807 * state.x) % 2147483647
    local r = (state.x - 1) / 2147483646
    if m == nil then
      return r
    end
    if n == nil then
      -- not `m, n = 1, m`: gopher-lua assigns locals sequentially (AGENTS.md)
      n = m
      m = 1
    end
    return m + math.floor(r * (n - m + 1))
  end
end
testing.random = make_random

--- testing.host{ now, epoch, seed, env, responses, transport, exec } -> host
-- A host for the contract in docs/interfaces.md with a fake clock: `sleep(s)` advances
-- `now()` by s at once and appends s to `host.sleeps`. `epoch()` is `epoch0 + now()`
-- (default 1700000000). State lives in a table (see compat.pcall on gopher-lua).
function testing.host(opts)
  opts = opts or {}
  local clock = { now = opts.now or 0, epoch0 = opts.epoch or 1700000000 }
  local env = opts.env or {}
  local host = { sleeps = {}, clock = clock, env = env }
  host.transport = opts.transport or testing.transport({ responses = opts.responses or {} })
  host.requests = host.transport.requests
  function host.now()
    return clock.now
  end
  function host.epoch()
    return clock.epoch0 + clock.now
  end
  function host.sleep(seconds)
    if type(seconds) ~= "number" or seconds ~= seconds then
      compat.raise("testing.host: sleep needs a number of seconds", 2)
    end
    host.sleeps[#host.sleeps + 1] = seconds
    if seconds > 0 then
      clock.now = clock.now + seconds
    end
  end
  function host.advance(seconds)
    clock.now = clock.now + seconds
  end
  host.random = make_random(opts.seed or 1)
  function host.getenv(name)
    return env[name]
  end
  host.exec = opts.exec
  return host
end

return testing
