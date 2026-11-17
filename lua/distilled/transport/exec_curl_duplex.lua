-- The duplex entry point (distilled.transport.curl_duplex) over an `exec.start` with
-- Rex's contract (rex.exec.start; distilled.host.rex passes it in):
--   start(argv, { stdin = true, stdout = fn(piece), stderr = fn(piece) }) -> h | nil, msg
--   h:write(data) -> true | nil, msg; h:close_stdin(); h:wait(seconds) -> result | nil,
--   "timeout"; h:kill(); result = { code, ok, stdout, stderr, timed_out }
--
--   local duplex = require("distilled.transport.exec_curl_duplex")(rex.exec.start [, opts])
--   local stream = require("distilled.transport.exec_curl_duplex").streaming(start [, opts])
--   opts = { curl = "curl", poll_s = 0.05 }
-- `streaming` is the one-way form: the body follows the config on stdin (`data-binary =
-- "@-"`), stdin is closed, and the response is read as it arrives.
--
-- The config reaches curl on stdin, ahead of the body, with no file and no argument:
--   sh -c 'exec 3<&0; dd bs=1 count="$1" 2>/dev/null | "$2" -q --config /dev/fd/4 4<&0 0<&3 3<&-'
-- dd copies exactly the config's bytes into a pipe that curl reads as its config (fd 4);
-- curl's own stdin is the original one (fd 3 moved back to 0), positioned at the body,
-- which `upload-file = "."` reads without blocking. Output arrives through the stdout
-- callback while read_* wait in h:wait(poll_s) (measured in Rex: pieces arrive as curl
-- writes them, binary bytes intact).
local curl_duplex = require("distilled.transport.curl_duplex")
local common = require("distilled.transport.curl_common")
local compat = require("distilled.compat")

local SCRIPT =
  'exec 3<&0; dd bs=1 count="$1" 2>/dev/null | "$2" -q --config /dev/fd/4 4<&0 0<&3 3<&-'

local function open(start, opts, one_way)
  if type(start) ~= "function" and not (type(start) == "table" and getmetatable(start)) then
    compat.raise("exec_curl_duplex: expected start(argv, opts) (for example rex.exec.start)", 2)
  end
  opts = opts or {}
  local curl = opts.curl or "curl"
  local poll = opts.poll_s or 0.05

  return function(req)
    local ok, err = common.check(req)
    if not ok then
      return nil, err
    end
    if req.body ~= nil and not one_way then
      return nil,
        require("distilled.errors").new("InvalidInput", {
          message = "transport.duplex: the body is written through conn:write, not request.body",
          member = "body",
        })
    end
    local config = curl_duplex.config(req, one_way and req.body ~= nil and "-" or nil)
    local out, err_parts = {}, {}
    local buffered = "" -- what read_* have not taken yet
    local h, serr = start({ "sh", "-c", SCRIPT, "sh", tostring(#config), curl }, {
      stdin = true,
      stdout = function(piece)
        out[#out + 1] = piece
      end,
      stderr = function(piece)
        err_parts[#err_parts + 1] = piece
      end,
    })
    if not h then
      return nil, common.failure({ not_found = true, message = tostring(serr), request = req })
    end
    local exited -- the wait result once the process ended
    local function pump()
      if #out > 0 then
        buffered = buffered .. compat.concat(out)
        out = {}
        return true
      end
      if exited then
        return false
      end
      local r = h:wait(poll)
      if type(r) == "table" then
        exited = r
      end
      if #out > 0 then
        buffered = buffered .. compat.concat(out)
        out = {}
      end
      return true
    end
    local wok, werr = h:write(config)
    if not wok then
      h:kill()
      return nil, common.failure({ message = tostring(werr), request = req })
    end
    local proc = {}
    function proc.write(bytes)
      if exited then
        return nil, "curl has exited"
      end
      return h:write(bytes)
    end
    function proc.close_stdin()
      h:close_stdin()
    end
    function proc.read(n)
      while #buffered < n do
        if not pump() then
          break
        end
      end
      local piece = string.sub(buffered, 1, n)
      buffered = string.sub(buffered, n + 1)
      return piece
    end
    function proc.read_line()
      while not string.find(buffered, "\n", 1, true) do
        if not pump() then
          break
        end
      end
      local i = string.find(buffered, "\n", 1, true)
      local line
      if i then
        line = string.sub(buffered, 1, i)
        buffered = string.sub(buffered, i + 1)
      else
        line = buffered
        buffered = ""
      end
      return line
    end
    function proc.finish()
      while not exited do
        local r = h:wait(5)
        if type(r) == "table" then
          exited = r
        end
      end
      return exited.code, compat.concat(err_parts) .. tostring(exited.stderr or "")
    end
    function proc.kill()
      if not exited then
        h:kill()
        local r = h:wait(2)
        exited = type(r) == "table" and r or { code = -1 }
      end
    end
    local conn = curl_duplex.conn(proc, req)
    if one_way then
      if req.body ~= nil then
        local bok, berr = h:write(req.body)
        if not bok then
          conn:close()
          return nil, common.failure({ message = tostring(berr), request = req })
        end
      end
      h:close_stdin()
      local res, rerr = conn:response()
      if not res then
        conn:close()
      end
      return res, rerr
    end
    return conn
  end
end

local function new(start, opts)
  return open(start, opts, false)
end

local function streaming(start, opts)
  return open(start, opts, true)
end

return setmetatable({ new = new, streaming = streaming }, {
  __call = function(_, start, opts)
    return new(start, opts)
  end,
})
