-- Runs every spec listed in spec/manifest.lua.
--
--   lua spec/run.lua [filter]        luajit spec/run.lua [filter]
--   rex do spec/run.lua [filter=<filter>]
--
-- A filter is a plain substring matched against the spec file name and the full test
-- name ("describe > it"). Exits non-zero on failure; under Rex it raises, which makes
-- `rex do` print "Error: FAIL ..." and exit 1.
--
-- Rex has no io.popen, so the spec list cannot be discovered here: verify/dl keeps
-- spec/manifest.lua current, and `dl doctor` fails when it is stale.

-- Where this file lives. lua/luajit report "@<path as invoked>" (relative or absolute);
-- gopher-lua reports the absolute path without the "@".
local function script_dir()
  local source = debug.getinfo(1, "S").source or ""
  source = string.gsub(source, "^@", "")
  local dir = string.match(source, "^(.*)/[^/]*$")
  return dir or "."
end

local function repo_root()
  local dir = script_dir()
  if dir == "spec" then
    return "."
  end
  local parent = string.match(dir, "^(.*)/spec$")
  if parent then
    return parent == "" and "/" or parent
  end
  return dir .. "/.."
end

local ROOT = repo_root()
package.path = ROOT
  .. "/lua/?.lua;"
  .. ROOT
  .. "/lua/?/init.lua;"
  .. ROOT
  .. "/?.lua;"
  .. package.path

local rex_api = rawget(_G, "rex")

local function runtime_name()
  if rex_api then
    return "rex"
  end
  if rawget(_G, "jit") then
    return "luajit"
  end
  return _VERSION
end

local function read_filter()
  if rex_api then
    local args = rawget(rex_api, "args") or {}
    return args.filter or args[1]
  end
  local a = rawget(_G, "arg")
  return a and a[1]
end

local t = require("spec.harness")
t.root = ROOT

local manifest_ok, manifest = t.pcall(function()
  return dofile(ROOT .. "/spec/manifest.lua")
end)
if not manifest_ok or type(manifest) ~= "table" then
  local message = "FAIL cannot load spec/manifest.lua (run verify/dl manifest): "
    .. tostring(manifest)
  if rex_api then
    error(message, 0)
  end
  print(message)
  os.exit(1)
end

local filter = read_filter()
if filter == "" then
  filter = nil
end

-- counters live in a table: see compat.pcall for the gopher-lua upvalue bug
local count = { passed = 0, failed = 0, skipped = 0 }
local lines = {}

local function report(file, name, failure)
  count.failed = count.failed + 1
  local where = failure.where and (" (" .. failure.where .. ")") or ""
  lines[#lines + 1] = "FAIL " .. file .. ": " .. name .. where
  lines[#lines + 1] = "  " .. string.gsub(tostring(failure.message), "\n", "\n  ")
end

for _, file in ipairs(manifest) do
  local path = "spec/" .. file
  t._set_file(path)
  local chunk, load_err = loadfile(ROOT .. "/" .. path)
  if not chunk then
    if not filter or string.find(path, filter, 1, true) then
      report(path, "(load)", { message = tostring(load_err) })
    end
  else
    local ok, raised = t.pcall(chunk)
    local tests = t._take_tests()
    if not ok then
      if not filter or string.find(path, filter, 1, true) then
        report(path, "(top level)", { message = tostring(raised) })
      end
    end
    local file_matches = filter and string.find(path, filter, 1, true)
    for _, test in ipairs(tests) do
      if not filter or file_matches or string.find(test.name, filter, 1, true) then
        if test.pending then
          count.skipped = count.skipped + 1
        else
          local failure = t._run(test)
          if failure then
            report(path, test.name, failure)
          else
            count.passed = count.passed + 1
          end
        end
      end
    end
  end
end

for _, line in ipairs(lines) do
  print(line)
end

local passed, failed, skipped = count.passed, count.failed, count.skipped
local summary
if failed > 0 then
  summary = string.format("FAIL %d failed, %d passed", failed, passed)
elseif passed == 0 then
  failed = 1
  summary = "FAIL no tests ran"
    .. (filter and (" (filter " .. string.format("%q", filter) .. ")") or "")
else
  summary = string.format("ok %d passed", passed)
end
if skipped > 0 then
  summary = summary .. string.format(", %d pending", skipped)
end
summary = summary .. " [" .. runtime_name() .. "]"

if rex_api then
  if failed > 0 then
    error(summary, 0)
  end
  print(summary)
  return
end
print(summary)
os.exit(failed > 0 and 1 or 0)
