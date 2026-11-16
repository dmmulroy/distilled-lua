-- Lua side of `dl serve` (verify/lib/serve.py), for specs and scripts:
--
--   local serve = require("verify.lib.serve")
--   serve.url()                      -- DL_SERVE_URL, or nil when no server was started
--   local s = serve.client(transport) -- control the server through a transport
--   s.script("/x", { { status = 500 }, { status = 200, json = { ok = true } } })
--   s.requests() -> list of { method, path, query, headers, body, body_b64, body_length }
--   s.reset()
--   serve.popen_exec(argv, opts)     -- rex.exec's contract on stock Lua (io.popen)
--   serve.pattern_bytes(n)           -- what GET /_dl/bytes?n=N returns
local json = require("distilled.json")

local serve = {}

function serve.url()
  local url = os.getenv("DL_SERVE_URL")
  if url == nil or url == "" then
    return nil
  end
  return url
end

-- byte i (0-based) is i % 256
function serve.pattern_bytes(n)
  local chars = {}
  for i = 0, 255 do
    chars[#chars + 1] = string.char(i)
  end
  local block = table.concat(chars)
  local whole = math.floor(n / 256)
  return string.rep(block, whole) .. string.sub(block, 1, n - whole * 256)
end

function serve.client(transport, base)
  base = base or serve.url()
  if not base then
    error(
      "serve.client: DL_SERVE_URL is not set (run under verify/dl serve run or dl test --http)",
      2
    )
  end
  local s = { base = base }
  local function call(method, path, value)
    local body = value ~= nil and json.encode(value) or nil
    local res, err = transport({
      method = method,
      url = base .. path,
      headers = body and { ["content-type"] = "application/json" } or {},
      body = body,
      timeout = 10,
    })
    if not res then
      error("dl serve " .. path .. ": " .. tostring(err), 3)
    end
    if res.status ~= 200 then
      error("dl serve " .. path .. ": HTTP " .. res.status .. " " .. res.body, 3)
    end
    return json.decode(res.body)
  end
  function s.url(path)
    return base .. (path or "")
  end
  function s.script(path, responses, opts)
    return call("POST", "/_dl/script", {
      path = path,
      responses = json.array(responses),
      repeat_last = opts and opts.repeat_last or false,
    })
  end
  function s.reset()
    return call("POST", "/_dl/reset", json.object({}))
  end
  function s.requests()
    return call("GET", "/_dl/requests")
  end
  return s
end

-- a word for /bin/sh
local function sh_quote(v)
  return "'" .. string.gsub(tostring(v), "'", "'\\''") .. "'"
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local data = f:read("*a") or ""
  f:close()
  return data
end

--- serve.popen_exec(argv, { stdin, timeout }) -> { code, ok, stdout, stderr, timed_out }
-- | nil, message. rex.exec's contract, on io.popen, so exec_curl's code path runs under
-- lua and luajit too. stdin goes through a mktemp (0600) file. `timeout` is not enforced
-- (curl's own --max-time is); a missing program is the shell's exit status 127.
function serve.popen_exec(argv, opts)
  opts = opts or {}
  local mk =
    io.popen('mktemp "${TMPDIR:-/tmp}/dl-exec.XXXXXX"; mktemp "${TMPDIR:-/tmp}/dl-exec.XXXXXX"')
  local paths = {}
  for line in string.gmatch(mk:read("*a"), "[^\n]+") do
    paths[#paths + 1] = line
  end
  mk:close()
  local in_path, err_path = paths[1], paths[2]
  local f = io.open(in_path, "wb")
  f:write(opts.stdin or "")
  f:close()
  local words = {}
  for i, a in ipairs(argv) do
    words[i] = sh_quote(a)
  end
  local cmd = "command -v "
    .. sh_quote(argv[1])
    .. " >/dev/null 2>&1 || { printf '\\n%d' 255; exit 0; }; "
    .. table.concat(words, " ")
    .. " <"
    .. sh_quote(in_path)
    .. " 2>"
    .. sh_quote(err_path)
    .. "; printf '\\n%d' \"$?\""
  local p = io.popen(cmd, "r")
  local out = p:read("*a") or ""
  p:close()
  local stderr = read_all(err_path)
  os.remove(in_path)
  os.remove(err_path)
  local i, _, code = string.find(out, "\n(%d+)$", math.max(1, #out - 16))
  if not i then
    return nil, "popen_exec: no exit status"
  end
  code = tonumber(code)
  if code == 255 and stderr == "" then
    return nil, tostring(argv[1]) .. ": executable file not found in PATH"
  end
  out = string.sub(out, 1, i - 1)
  return { code = code, ok = code == 0, stdout = out, stderr = stderr, timed_out = false }
end

return serve
