-- The Lua side of `verify/dl trace` and `verify/dl expect`. Runs under lua, luajit and
-- gopher-lua (rex do), so it uses only io.open for files (Rex has no io.popen).
--
--   lua trace_run.lua <mode> <script-or-file> [level] [out]
--   rex do trace_run.lua mode=<mode> path=<script-or-file> level=<level> out=<out>
--
-- mode trace:  run the script with a tracer (verify/lib/trace_env.lua), write OTLP/JSON
--              lines to <out>, print the span tree.
-- mode expect: as trace, then call the function the script returned (if any) with
--              expect(spans); a raised assertion fails the run.
-- mode file:   print the tree of an existing OTLP/JSON lines file.
-- Exit status (non-Rex) is 0 on success and 1 on failure; under Rex failure raises,
-- which `rex do` reports as "Error: ..." with exit 1.
local function script_dir()
  local source = debug.getinfo(1, "S").source or ""
  source = string.gsub(source, "^@", "")
  return string.match(source, "^(.*)/[^/]*$") or "."
end

local ROOT = script_dir() .. "/../.."
package.path = ROOT
  .. "/lua/?.lua;"
  .. ROOT
  .. "/lua/?/init.lua;"
  .. ROOT
  .. "/?.lua;"
  .. package.path

local compat = require("distilled.compat")
local rex_api = rawget(_G, "rex")

local args = {}
if rex_api then
  local a = rawget(rex_api, "args") or {}
  args.mode, args.path, args.level, args.out = a.mode, a.path, a.level, a.out
else
  local a = rawget(_G, "arg") or {}
  args.mode, args.path, args.level, args.out = a[1], a[2], a[3], a[4]
end
if args.level == "" then
  args.level = nil
end
if args.out == "" then
  args.out = nil
end

local function finish(ok, message)
  if message then
    print(message)
  end
  if rex_api then
    if not ok then
      error("dl: failed", 0)
    end
    return
  end
  os.exit(ok and 0 or 1)
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local text = f:read("*a")
  f:close()
  return text
end

local tree = require("distilled.trace.tree")

if args.mode == "file" then
  local otlp = require("distilled.trace.otlp")
  local text, err = read_file(args.path or "")
  if not text then
    return finish(false, "dl trace: cannot read " .. tostring(args.path) .. ": " .. tostring(err))
  end
  local spans, derr = otlp.decode_lines(text)
  if not spans then
    return finish(false, "dl trace: " .. tostring(derr))
  end
  io.write(tree.render(spans))
  return finish(true, string.format("(%d spans from %s)", #spans, args.path))
end

if args.mode ~= "trace" and args.mode ~= "expect" then
  return finish(false, "trace_run: mode must be trace, expect or file")
end

if args.out then
  -- start each run with a fresh file
  local f = io.open(args.out, "wb")
  if f then
    f:close()
  end
end

local env = require("verify.lib.trace_env")
env.install({ level = args.level or "debug", file = args.out })

local chunk, load_err = loadfile(args.path or "")
if not chunk then
  return finish(false, "dl: cannot load script: " .. tostring(load_err))
end

local function describe(raised)
  local text = tostring(raised)
  if debug and debug.traceback then
    text = debug.traceback(text, 2)
  end
  return text
end

local ran = compat.pack(xpcall(chunk, describe))
local flushed, flush_err = env.flush()
local spans = env.memory.spans

io.write(tree.render(spans))
print(
  string.format(
    "(%d spans, level %s%s)",
    #spans,
    env.tracer.level,
    args.out and (", otlp " .. args.out) or ""
  )
)
if not flushed then
  print("dl: trace flush failed: " .. tostring(flush_err))
end
if not ran[1] then
  return finish(false, "dl: script raised: " .. tostring(ran[2]))
end

if args.mode == "expect" then
  local check = ran[2]
  if type(check) == "function" then
    local expect = require("distilled.trace.expect")
    local ok, raised = xpcall(function()
      return check(expect(spans), spans)
    end, function(e)
      return e
    end)
    if not ok then
      return finish(false, "expect: FAIL\n" .. tostring(raised))
    end
  end
  return finish(flushed and true or false, "expect: ok")
end
return finish(flushed and true or false)
