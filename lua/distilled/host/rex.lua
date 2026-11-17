-- The Rex host adapter: the only module in the library that names `rex`.
--
--   local host = require("distilled.host.rex")([opts])
--   opts = { curl = "curl", margin_s = 2 }   -- passed to exec_curl
--
-- Works in the Rex configuration file (inside an action) and in `rex do` scripts:
-- * transport: exec_curl over rex.exec (io.popen and os.execute raise in Rex);
-- * now: os.clock, which is wall time in gopher-lua (CPU time elsewhere);
-- * sleep: rex.sleep in scripts; in the configuration file rex.sleep is nil, and
--   rex.exec{ "sleep", s } waits while letting the server handle other work;
-- * epoch: os.time (whole seconds; the tracer adds sub-second precision from now);
-- * random is left to distilled.host's default: math.random starts from a fixed seed
--   in some runtimes, which would repeat trace ids between runs.
local exec_curl = require("distilled.transport.exec_curl")
local compat = require("distilled.compat")

local function format_seconds(s)
  -- `sleep` takes a decimal; %.3f keeps 0.05 as 0.050 rather than 5e-02
  return string.format("%.3f", s)
end

return function(opts)
  local rex = rawget(_G, "rex")
  if type(rex) ~= "table" or (type(rex.exec) ~= "function" and type(rex.exec) ~= "table") then
    compat.raise(
      "distilled.host.rex: the global `rex` (with rex.exec) is missing; this host only works inside Rex "
        .. "(rex do, or the Rex configuration file). Elsewhere use the default host "
        .. "(popen_curl) or build one with distilled.transport.exec_curl.",
      2
    )
  end
  local exec = rex.exec
  -- rex.exec may be a callable table (it also has rex.exec.start); wrap it so exec_curl
  -- and callers get a plain function
  local function rex_exec(argv, o)
    return exec(argv, o)
  end

  local sleep
  if type(rawget(rex, "sleep")) == "function" then
    local rex_sleep = rex.sleep
    sleep = function(seconds)
      if type(seconds) == "number" and seconds > 0 then
        rex_sleep(seconds)
      end
    end
  else
    sleep = function(seconds)
      if type(seconds) == "number" and seconds > 0 then
        exec({ "sleep", format_seconds(seconds) }, { timeout = seconds + 5 })
      end
    end
  end

  local transport = exec_curl(rex_exec, opts)
  -- streaming and full-duplex entry points over rex.exec.start (task 31: AWS event
  -- streams): stdin kept open for h:write, stdout pieces drained with h:wait
  local starter = type(exec) == "table" and rawget(exec, "start")
  if starter then
    local function start(argv, o)
      return starter(argv, o)
    end
    local duplex_mod = require("distilled.transport.exec_curl_duplex")
    transport = require("distilled.transport.curl_duplex").with_entries(transport, {
      stream = duplex_mod.streaming(start, opts),
      duplex = duplex_mod.new(start, opts),
    })
  end
  return {
    transport = transport,
    exec = rex_exec,
    sleep = sleep,
    now = os.clock,
    epoch = os.time,
    getenv = os.getenv,
    name = "rex",
  }
end
