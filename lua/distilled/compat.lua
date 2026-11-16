-- Small shims for what differs between Lua 5.1, LuaJIT, 5.2+ (here 5.5) and gopher-lua.
-- Anything version-specific belongs here so the rest of the library can stay on 5.1.
local compat = {}

-- `unpack` is a global in 5.1/LuaJIT/gopher-lua, `table.unpack` in 5.2+.
-- gopher-lua has no `table.unpack`, 5.5 has no `unpack`.
compat.unpack = rawget(table, "unpack") or rawget(_G, "unpack")

-- Like 5.2's table.pack: keeps trailing nils countable through `n`.
function compat.pack(...)
  return { n = select("#", ...), ... }
end

local loadstring_fn = rawget(_G, "loadstring")

-- compat.pcall(fn, ...) -> true, ... | false, raised
-- Use this instead of pcall. In gopher-lua (Rex), a pcall that catches an error closes
-- every open upvalue of the frames still running, so a closure created earlier keeps
-- writing to a stale copy of its variable (measured: `local n = 0; local function bump()
-- n = n + 1 end; pcall(error, "x"); bump()` leaves n == 0). xpcall does not have the
-- bug. 5.1's xpcall takes no arguments, so they travel in a closure.
local function identity(raised)
  return raised
end

function compat.pcall(fn, ...)
  local n = select("#", ...)
  if n == 0 then
    return xpcall(fn, identity)
  end
  local args = { ... }
  return xpcall(function()
    return fn(compat.unpack(args, 1, n))
  end, identity)
end

-- gopher-lua reports error(msg, level) at level - 1 (error(msg, 2) names the function
-- that raised, not its caller). Measure once, so compat.raise names the right line.
local LEVEL_SHIFT = 0
do
  local getinfo = debug and debug.getinfo
  if getinfo then
    -- error(_, 2) should name the caller; if the reported line falls inside thrower
    -- itself, the runtime is off by one.
    local function thrower()
      error("probe", 2)
    end
    local ok, message = xpcall(thrower, identity)
    local info = getinfo(thrower, "S")
    local line = type(message) == "string" and tonumber(string.match(message, ":(%d+): probe$"))
    if not ok and info and line and line >= info.linedefined and line <= info.lastlinedefined then
      LEVEL_SHIFT = 1
    end
  end
end
compat.ERROR_LEVEL_SHIFT = LEVEL_SHIFT

-- compat.raise(message, level): error(message, level) with gopher-lua's level fixed.
-- Level 1 is the function calling compat.raise, 2 its caller, as with error().
function compat.raise(message, level)
  level = level or 1
  if level <= 0 then
    error(message, 0)
  end
  error(message, level + 1 + LEVEL_SHIFT)
end

-- compat.load(chunk_string, chunkname) -> fn | nil, message
-- 5.5's `load` takes strings; 5.1's `load` takes only functions, so use loadstring there.
function compat.load(chunk, chunkname)
  if type(chunk) ~= "string" then
    error("compat.load: chunk must be a string", 2)
  end
  if loadstring_fn then
    return loadstring_fn(chunk, chunkname)
  end
  return load(chunk, chunkname, "t")
end

-- 5.3+ distinguishes integer and float subtypes; tostring(1.0) is "1.0" there.
-- compat.normalize_number turns an integral float into an integer where that subtype
-- exists, so decoded data prints the same on every runtime.
local math_tointeger = rawget(math, "tointeger")
local TWO_53 = 9007199254740992

function compat.normalize_number(n)
  if math_tointeger and n == n and n > -TWO_53 and n < TWO_53 and n == math.floor(n) then
    -- keep -0.0 as a float: tointeger would drop the sign
    if n == 0 and 1 / n < 0 then
      return n
    end
    return math_tointeger(n) or n
  end
  return n
end

-- True when the runtime has an integer subtype and n is stored as one.
local math_type = rawget(math, "type")
function compat.is_integer_subtype(n)
  return math_type ~= nil and math_type(n) == "integer"
end

-- gopher-lua's table.concat pushes every item onto its registry and fails with
-- "registry overflow" past about 2,500 items (measured: 2559 from a shallow stack).
-- compat.concat joins in chunks so any length works everywhere.
local CONCAT_CHUNK = 500
local table_concat = table.concat

function compat.concat(list, sep)
  sep = sep or ""
  local n = #list
  if n <= CONCAT_CHUNK then
    return table_concat(list, sep)
  end
  local parts, np = {}, 0
  for i = 1, n, CONCAT_CHUNK do
    local j = i + CONCAT_CHUNK - 1
    if j > n then
      j = n
    end
    np = np + 1
    parts[np] = table_concat(list, sep, i, j)
  end
  return compat.concat(parts, sep)
end

return compat
