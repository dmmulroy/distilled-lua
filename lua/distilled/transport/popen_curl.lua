-- A curl transport for stock Lua and LuaJIT, through io.popen. (Rex has no io.popen; use
-- exec_curl there, or distilled.host.rex.)
--
--   local transport = require("distilled.transport.popen_curl")([opts])
--   opts = { curl = "curl", follow_redirects = false, tmpdir = nil ($TMPDIR or /tmp) }
--
-- io.popen gives one direction only: we can read curl's stdout or write its stdin, not
-- both. Reading stdout matters more (the response may be megabytes), so the request goes
-- through files instead of stdin:
-- * `mktemp` creates each file (config, body, stderr) with mode 0600 at creation
--   (mkstemp), so no file is readable by another user at any moment; io.open on an
--   existing file keeps its mode. The shell that runs curl also sets `umask 077`.
-- * The config file holds the URL, method and headers (the API key); the body file
--   holds the exact body bytes; stderr goes to its own file so it cannot mix with the
--   body on stdout.
-- * Every file is removed by a scope finalizer, on success, on failure and on a raise.
-- * curl's argv names only file paths: `curl -q --config <path>`. Its exit status is
--   printed after the output (LuaJIT's pipe close does not return it).
local common = require("distilled.transport.curl_common")
local errors = require("distilled.errors")
local compat = require("distilled.compat")
local Scope = require("distilled.scope")

-- a word for /bin/sh: single-quoted, with embedded single quotes closed and escaped
local function sh_quote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function transport_error(message)
  return errors.new("TransportError", { message = message })
end

-- runs a shell command and returns its whole stdout, or nil, err
local function read_command(cmd)
  local popen = io.popen
  if type(popen) ~= "function" then
    return nil, transport_error("popen_curl: io.popen is not available here (in Rex use exec_curl)")
  end
  local ok, f = compat.pcall(popen, cmd, "r")
  if not ok or not f then
    return nil,
      transport_error(
        "popen_curl: io.popen failed"
          .. (ok and "" or (": " .. tostring(f)))
          .. " (in Rex use exec_curl)"
      )
  end
  local out = f:read("*a")
  f:close()
  return out or ""
end

-- makes n temp files with mktemp in dir (default $TMPDIR, else /tmp); returns a list of
-- paths or nil, err
local function make_temp_files(n, dir)
  local template = dir and sh_quote(dir .. "/distilled-curl.XXXXXX")
    or '"${TMPDIR:-/tmp}/distilled-curl.XXXXXX"'
  local cmds = {}
  for i = 1, n do
    cmds[i] = "mktemp " .. template
  end
  local out, err = read_command("umask 077; " .. table.concat(cmds, " && "))
  if not out then
    return nil, err
  end
  local paths = {}
  for line in string.gmatch(out, "[^\n]+") do
    paths[#paths + 1] = line
  end
  if #paths ~= n then
    for _, p in ipairs(paths) do
      os.remove(p)
    end
    return nil, transport_error("popen_curl: mktemp failed")
  end
  return paths
end

local function write_file(path, data)
  local f, open_err = io.open(path, "wb")
  if not f then
    return nil, transport_error("popen_curl: cannot write a temp file: " .. tostring(open_err))
  end
  local ok, write_err = f:write(data)
  f:close()
  if not ok then
    return nil, transport_error("popen_curl: cannot write a temp file: " .. tostring(write_err))
  end
  return true
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local data = f:read("*a") or ""
  f:close()
  return data
end

local function new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    compat.raise("popen_curl: expected an options table", 2)
  end
  local curl = opts.curl or "curl"
  local config_opts =
    { follow_redirects = opts.follow_redirects, max_redirects = opts.max_redirects }

  local function send(scope, req)
    local has_body = req.body ~= nil
    local paths, err = make_temp_files(has_body and 3 or 2, opts.tmpdir)
    if not paths then
      return nil, err
    end
    scope:defer(function()
      for _, p in ipairs(paths) do
        os.remove(p)
      end
    end)
    local config_path, stderr_path, body_path = paths[1], paths[2], paths[3]
    local ok, write_err
    if has_body then
      ok, write_err = write_file(body_path, req.body)
      if not ok then
        return nil, write_err
      end
    end
    local o = {}
    for k, v in pairs(config_opts) do
      o[k] = v
    end
    o.body_path = body_path
    ok, write_err = write_file(config_path, common.config(req, o))
    if not ok then
      return nil, write_err
    end
    local cmd = "umask 077; "
      .. sh_quote(curl)
      .. " -q --config "
      .. sh_quote(config_path)
      .. " 2>"
      .. sh_quote(stderr_path)
      .. "; printf '\\n%d' \"$?\""
    local out, run_err = read_command(cmd)
    if not out then
      return nil, run_err
    end
    -- the exit status is the last line
    local status_at = nil
    local from = #out - 16
    if from < 1 then
      from = 1
    end
    local i, _, code = string.find(out, "\n(%d+)$", from)
    if i then
      status_at = i
    end
    if not status_at then
      return nil, transport_error("popen_curl: the shell printed no exit status")
    end
    code = tonumber(code)
    out = string.sub(out, 1, status_at - 1)
    if code ~= 0 then
      return nil, common.failure({ code = code, stderr = read_file(stderr_path), request = req })
    end
    return common.parse(out, req)
  end

  return function(req)
    local ok, err = common.check(req)
    if not ok then
      return nil, err
    end
    return Scope.with(function(scope)
      return send(scope, req)
    end)
  end
end

--- popen_curl.sleep(seconds): wait in a child `sleep` process (wall time; stock Lua has
-- no sleep). Lives here because this is the one core module allowed to use io.popen
-- (AGENTS.md); distilled.host.popen hands it to clients. Ignores non-positive, NaN and
-- non-number values.
local function shell_sleep(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds or seconds <= 0 then
    return
  end
  local p = io.popen(string.format("sleep %.3f", seconds))
  if p then
    p:read("*a")
    p:close()
  end
end

---------------------------------------------------------------------------------------
-- full duplex (task 31): the request body written while the response is read
---------------------------------------------------------------------------------------

-- popen_curl.duplex([opts]) -> duplex(request) -> conn (distilled.transport.curl_duplex)
-- popen_curl.streaming([opts]) -> stream(request) -> { status, headers, body = reader }:
--   the same machinery one way (the body from a file in that directory, stdin empty),
--   for a response read as it arrives
-- io.popen is one-way, so curl runs in the background with its stdin and stdout on two
-- FIFOs in a private directory (mktemp -d, mode 0700): Lua writes the body into one and
-- reads the response from the other, each through io.open, as it comes. The directory
-- also holds the config (the request's URL and headers), curl's stderr, its pid and its
-- exit status; it is removed when the transfer ends or is closed. Lua keeps a reader of
-- its own on the stdin FIFO, so a write after curl exited cannot kill the process with
-- SIGPIPE (the status file is checked before every write instead).
local function transfer_new(opts, one_way)
  opts = opts or {}
  local curl = opts.curl or "curl"
  local curl_duplex = require("distilled.transport.curl_duplex")
  return function(req)
    local ok, err = common.check(req)
    if not ok then
      return nil, err
    end
    if req.body ~= nil and not one_way then
      return nil,
        errors.new("InvalidInput", {
          message = "transport.duplex: the body is written through conn:write, not request.body",
          member = "body",
        })
    end
    local template = opts.tmpdir and sh_quote(opts.tmpdir .. "/distilled-duplex.XXXXXX")
      or '"${TMPDIR:-/tmp}/distilled-duplex.XXXXXX"'
    local dir, derr = read_command(
      "umask 077; d=$(mktemp -d " .. template .. ') && mkfifo "$d/in" "$d/out" && printf %s "$d"'
    )
    if not dir or dir == "" or string.find(dir, "[\r\n]") then
      return nil, derr or transport_error("popen_curl: mktemp -d / mkfifo failed")
    end
    local files = { "config", "body", "in", "out", "err", "pid", "status" }
    local function path(name)
      return dir .. "/" .. name
    end
    local w, keep, r
    local cleaned = false
    local function cleanup()
      if cleaned then
        return
      end
      cleaned = true
      for _, f in ipairs({ w, keep, r }) do
        if f then
          compat.pcall(function()
            f:close()
          end)
        end
      end
      for _, name in ipairs(files) do
        os.remove(path(name))
      end
      os.remove(dir)
    end
    local wok, werr = write_file(
      path("config"),
      curl_duplex.config(req, one_way and req.body ~= nil and "body" or nil)
    )
    if wok and one_way and req.body ~= nil then
      wok, werr = write_file(path("body"), req.body)
    end
    if not wok then
      cleanup()
      return nil, werr
    end
    local script = "cd "
      .. sh_quote(dir)
      .. " && { "
      .. sh_quote(curl)
      .. " -q --config config <"
      .. (one_way and "/dev/null" or "in")
      .. " >out 2>err & echo $! >pid; wait $!; echo $? >status; }"
    local started, serr = read_command("umask 077; (" .. script .. ") >/dev/null 2>&1 </dev/null &")
    if not started then
      cleanup()
      return nil, serr
    end
    -- the same order as the shell's redirections (<in, then >out): neither side waits
    -- on a FIFO the other has not reached
    if not one_way then
      w = io.open(path("in"), "wb")
      keep = w and io.open(path("in"), "rb")
    end
    r = (one_way or keep) and io.open(path("out"), "rb")
    if not r then
      cleanup()
      return nil, transport_error("popen_curl: cannot open the duplex FIFOs")
    end
    if w and w.setvbuf then
      w:setvbuf("no")
    end
    local function exited()
      local f = io.open(path("status"), "rb")
      if f then
        f:close()
        return true
      end
      return false
    end
    local stdin_open = not one_way
    local proc = {}
    function proc.write(bytes)
      if not stdin_open then
        return nil, "the request body is closed"
      end
      if exited() then
        return nil, "curl has exited"
      end
      local okw, e = w:write(bytes)
      if okw then
        okw, e = w:flush()
      end
      if not okw then
        return nil, tostring(e)
      end
      return true
    end
    function proc.close_stdin()
      if stdin_open and w then
        stdin_open = false
        w:close()
        w = nil
      end
    end
    function proc.read(n)
      if cleaned then
        return ""
      end
      return r:read(n) or ""
    end
    function proc.read_line()
      if cleaned then
        return ""
      end
      local line = r:read("*l")
      if line == nil then
        return ""
      end
      return line .. "\n"
    end
    function proc.finish()
      local code
      for _ = 1, 200 do
        local text = read_file(path("status"))
        code = tonumber(string.match(text, "%d+"))
        if code then
          break
        end
        shell_sleep(0.05)
      end
      local stderr = read_file(path("err"))
      cleanup()
      return code or -1, stderr
    end
    function proc.kill()
      if not cleaned then
        if not exited() then
          local pid = string.match(read_file(path("pid")), "%d+")
          if pid then
            os.execute("kill " .. pid .. " 2>/dev/null")
          end
        end
        cleanup()
      end
    end
    local conn = curl_duplex.conn(proc, req)
    if one_way then
      local res, rerr = conn:response()
      if not res then
        conn:close()
      end
      return res, rerr
    end
    return conn
  end
end

-- transport_module: distilled.host.check refuses this table as a transport (task 09)
return setmetatable({
  new = new,
  sleep = shell_sleep,
  duplex = function(opts)
    return transfer_new(opts, false)
  end,
  streaming = function(opts)
    return transfer_new(opts, true)
  end,
  transport_module = "distilled.transport.popen_curl",
}, {
  __call = function(_, opts)
    return new(opts)
  end,
})
