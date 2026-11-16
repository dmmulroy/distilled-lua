-- A dependency-free test harness. Pure Lua 5.1: runs under lua, luajit and gopher-lua
-- (rex do). Spec files call t.describe / t.it at load time; spec/run.lua runs them.
--
-- Assertions take (actual, expected) in that order and raise a failure table, which the
-- runner catches with pcall (gopher-lua's assert cannot carry tables, so we never use it).
local t = {}

-- repository root, set by spec/run.lua (specs read fixtures through it)
t.root = "."

local state = {
  tests = {},
  names = {},
  file = "?",
}

-- pcall replacement: in gopher-lua a pcall that catches an error, and any protected
-- call that catches after another one completed inside it, break closures' upvalues in
-- the frames still running. compat.pcall runs fn in a coroutine, which is safe.
local compat = require("distilled.compat")
local function safe_pcall(fn)
  return compat.pcall(fn)
end
t.pcall = safe_pcall

local FAILURE_MT = {
  __tostring = function(f)
    return f.message
  end,
}

---------------------------------------------------------------------------------------
-- showing values
---------------------------------------------------------------------------------------

local function is_identifier(k)
  return type(k) == "string" and string.find(k, "^[%a_][%w_]*$") ~= nil
end

local function sorted_keys(v)
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
      return ta < tb
    end
    if ta == "number" or ta == "string" then
      return a < b
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function has_pairs(v)
  return next(v) ~= nil
end

-- t.show(value) -> a readable one-line rendering, keys sorted, long output cut.
local function show(v, seen, depth)
  local tv = type(v)
  if tv == "string" then
    return string.format("%q", v)
  elseif tv ~= "table" then
    return tostring(v)
  end
  local mt = getmetatable(v)
  if not has_pairs(v) and type(mt) == "table" and mt.__tostring then
    return tostring(v) -- json.null, secrets
  end
  seen = seen or {}
  depth = depth or 0
  if seen[v] then
    return "<cycle>"
  end
  if depth > 6 then
    return "{...}"
  end
  seen[v] = true
  local prefix = ""
  if type(mt) == "table" and mt.__jsontype then
    prefix = mt.__jsontype .. " "
  elseif type(mt) == "table" and mt.__tostring then
    prefix = "<" .. tostring(v) .. "> "
  end
  local parts = {}
  local n = #v
  for i = 1, n do
    parts[#parts + 1] = show(rawget(v, i), seen, depth + 1)
  end
  for _, k in ipairs(sorted_keys(v)) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
      local key = is_identifier(k) and k or ("[" .. show(k, seen, depth + 1) .. "]")
      parts[#parts + 1] = key .. " = " .. show(rawget(v, k), seen, depth + 1)
    end
  end
  seen[v] = nil
  return prefix .. "{ " .. table.concat(parts, ", ") .. (#parts > 0 and " }" or "}")
end

function t.show(v)
  local s = show(v)
  if #s > 600 then
    s = string.sub(s, 1, 600) .. " ... (" .. #s .. " chars)"
  end
  return s
end

---------------------------------------------------------------------------------------
-- failing
---------------------------------------------------------------------------------------

-- The line in the spec file that made the failing call.
local function spec_location()
  if not (debug and debug.getinfo) then
    return nil
  end
  for level = 3, 30 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      break
    end
    local src = info.source or ""
    if string.find(src, "_spec%.lua$") then
      src = string.gsub(src, "^@", "")
      src = string.match(src, "([^/]*/[^/]+)$") or src
      return src .. ":" .. tostring(info.currentline)
    end
  end
  return nil
end

local function fail(message)
  error(setmetatable({ message = message, where = spec_location() }, FAILURE_MT), 0)
end

function t.fail(message)
  fail(message or "failed")
end

function t.is_failure(v)
  return getmetatable(v) == FAILURE_MT
end

---------------------------------------------------------------------------------------
-- assertions
---------------------------------------------------------------------------------------

-- raw equality (==)
function t.eq(actual, expected, label)
  if actual ~= expected then
    fail(
      (label and (label .. ": ") or "")
        .. "values differ\n    expected: "
        .. t.show(expected)
        .. "\n    actual:   "
        .. t.show(actual)
    )
  end
end

function t.ne(actual, unexpected, label)
  if actual == unexpected then
    fail((label and (label .. ": ") or "") .. "expected a value other than " .. t.show(unexpected))
  end
end

local function path_join(path, k)
  if is_identifier(k) then
    return path .. "." .. k
  end
  return path .. "[" .. show(k) .. "]"
end

-- First difference between a and b as (path, a_value, b_value), or nil when equal.
-- Tables compare by content (raw access, metatables ignored).
local function first_difference(a, b, path, seen)
  if a == b then
    return nil
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    if type(a) == "number" and type(b) == "number" and a ~= a and b ~= b then
      return nil -- NaN equals NaN here
    end
    return path, a, b
  end
  seen[a] = seen[a] or {}
  if seen[a][b] then
    return nil
  end
  seen[a][b] = true
  for _, k in ipairs(sorted_keys(a)) do
    local p, x, y = first_difference(rawget(a, k), rawget(b, k), path_join(path, k), seen)
    if p then
      return p, x, y
    end
  end
  for _, k in ipairs(sorted_keys(b)) do
    if rawget(a, k) == nil then
      return path_join(path, k), nil, rawget(b, k)
    end
  end
  return nil
end
t.first_difference = function(a, b)
  return first_difference(a, b, "value", {})
end

-- deep equality
function t.same(actual, expected, label)
  local path, x, y = first_difference(actual, expected, "value", {})
  if path then
    fail(
      (label and (label .. ": ") or "")
        .. "tables differ at "
        .. path
        .. "\n    expected: "
        .. t.show(y)
        .. "\n    actual:   "
        .. t.show(x)
        .. "\n  whole expected: "
        .. t.show(expected)
        .. "\n  whole actual:   "
        .. t.show(actual)
    )
  end
end

function t.truthy(v, label)
  if not v then
    fail((label and (label .. ": ") or "") .. "expected a truthy value, got " .. t.show(v))
  end
end

function t.falsy(v, label)
  if v then
    fail((label and (label .. ": ") or "") .. "expected a falsy value, got " .. t.show(v))
  end
end

-- t.err(v, e, tag): the call returned nil, err with err.tag == tag (tag optional).
-- Returns e so the caller can inspect it further.
function t.err(v, e, tag)
  if v ~= nil then
    fail(
      "expected nil, err but the value was "
        .. t.show(v)
        .. (e ~= nil and (" (err " .. t.show(e) .. ")") or "")
    )
  end
  if type(e) ~= "table" or type(e.tag) ~= "string" then
    fail("expected an error table, got " .. t.show(e))
  end
  if tag ~= nil and e.tag ~= tag then
    fail(
      "expected error tag " .. t.show(tag) .. ", got " .. t.show(e.tag) .. ": " .. t.show(e.message)
    )
  end
  return e
end

-- t.fails_with(tag, f(...)): t.err with the tag first, so a call's results can be
-- passed straight in: t.fails_with("ParseError", json.decode("[")). Returns the err.
function t.fails_with(tag, v, e)
  return t.err(v, e, tag)
end

-- t.match(str, pattern [, plain]): a Lua pattern (or plain substring) found in str
function t.match(s, pattern, plain)
  if type(s) ~= "string" then
    fail("expected a string to match " .. t.show(pattern) .. ", got " .. t.show(s))
  end
  if not string.find(s, pattern, 1, plain == true) then
    fail(
      "string does not match\n    pattern: " .. t.show(pattern) .. "\n    string:  " .. t.show(s)
    )
  end
end

function t.no_match(s, pattern, plain)
  if type(s) == "string" and string.find(s, pattern, 1, plain == true) then
    fail("string should not contain " .. t.show(pattern) .. "\n    string:  " .. t.show(s))
  end
end

-- t.raises(fn [, pattern]) -> the raised value. Fails when fn returns normally, or when
-- the raised message does not match the Lua pattern.
function t.raises(fn, pattern)
  local ok, raised = safe_pcall(fn)
  if ok then
    fail("expected an error to be raised")
  end
  if pattern ~= nil then
    local text = tostring(raised)
    if not string.find(text, pattern) then
      fail(
        "raised error does not match\n    pattern: "
          .. t.show(pattern)
          .. "\n    raised:  "
          .. t.show(text)
      )
    end
  end
  return raised
end

---------------------------------------------------------------------------------------
-- registering
---------------------------------------------------------------------------------------

function t.describe(name, fn)
  local names = state.names
  names[#names + 1] = name
  local ok, raised = safe_pcall(fn)
  names[#names] = nil
  if not ok then
    -- a describe body that raises is reported as one failing test
    state.tests[#state.tests + 1] = {
      file = state.file,
      name = name .. " (describe body)",
      fn = function()
        error(raised, 0)
      end,
    }
  end
end

function t.it(name, fn)
  local full = table.concat(state.names, " > ")
  full = full == "" and name or (full .. " > " .. name)
  state.tests[#state.tests + 1] = { file = state.file, name = full, fn = fn }
end

-- registered but not run; counted as skipped
function t.pending(name)
  local full = table.concat(state.names, " > ")
  full = full == "" and name or (full .. " > " .. name)
  state.tests[#state.tests + 1] = { file = state.file, name = full, pending = true }
end

---------------------------------------------------------------------------------------
-- running (used by spec/run.lua)
---------------------------------------------------------------------------------------

function t._set_file(file)
  state.file = file
  state.names = {}
end

function t._take_tests()
  local tests = state.tests
  state.tests = {}
  return tests
end

local function traceback(raised)
  if t.is_failure(raised) then
    return raised
  end
  local text = tostring(raised)
  if debug and debug.traceback then
    -- called directly: inside a coroutine it would trace the wrong stack
    local tb = debug.traceback(text, 2)
    if type(tb) == "string" then
      text = tb
    end
  end
  return { message = "raised: " .. text }
end

-- run one test; returns nil on success or a failure { message, where }
-- The one xpcall left (for its traceback handler): it is the outermost protected call,
-- and everything nested inside uses compat.pcall, so gopher-lua's nested-call bug
-- cannot trigger.
function t._run(test)
  local ok, raised = xpcall(test.fn, traceback)
  if ok then
    return nil
  end
  return raised
end

return t
