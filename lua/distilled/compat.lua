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
