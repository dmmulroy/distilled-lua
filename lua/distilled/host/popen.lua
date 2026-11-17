-- A one-line host for stock Lua and LuaJIT:
--
--   local client = Neon.new({ host = require("distilled.host.popen")() })
--   opts = { curl = "curl", follow_redirects = false, tmpdir = nil }  -- passed to popen_curl
--
-- * transport: distilled.transport.popen_curl (curl through io.popen, request in 0600 files),
--   with `stream` and `duplex` entry points (curl in the background on FIFOs)
-- * sleep: a child `sleep` process (popen_curl.sleep), so retry backoff waits in wall time
--   instead of the default busy loop
-- * now, epoch: os.time (whole seconds: deadlines are checked to the second)
-- * no exec: credentials.from_command needs one; pass `exec` yourself if you use it
-- Rex has no io.popen: use distilled.host.rex there.
local compat = require("distilled.compat")

return function(opts)
  if rawget(_G, "rex") ~= nil or type(io.popen) ~= "function" then
    compat.raise(
      "distilled.host.popen: io.popen is not available here; inside Rex use distilled.host.rex",
      2
    )
  end
  local popen_curl = require("distilled.transport.popen_curl")
  -- streaming and full-duplex entry points (task 31: AWS event streams)
  local transport = require("distilled.transport.curl_duplex").with_entries(popen_curl(opts), {
    stream = popen_curl.streaming(opts),
    duplex = popen_curl.duplex(opts),
  })
  return {
    transport = transport,
    sleep = popen_curl.sleep,
    now = os.time,
    epoch = os.time,
    name = "popen",
  }
end
