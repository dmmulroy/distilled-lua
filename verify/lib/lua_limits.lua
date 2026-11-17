-- The compiler limits that bite generated code (task 18), probed in the runtime this runs
-- under: each probe builds a chunk of Lua source and compiles it with compat.load.
--
--   lua verify/lib/lua_limits.lua [quick]       rex do verify/lib/lua_limits.lua [quick=1]
--
-- Prints one line per probe: kind, size, "ok <compile ms>" or the compiler's message.
-- `quick` skips the slow sizes (gopher-lua takes ~7 s per 65,000 distinct constants).
local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
local root = (string.match(source, "^(.*)/verify/lib/[^/]*$")) or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local compat = require("distilled.compat")

local rex_api = rawget(_G, "rex")
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local quick = (rex_api and rex_api.args.quick) or (arg and arg[1] == "quick")

-- builders: n -> source
local KINDS = {
  -- n distinct string constants in one function, one statement each
  strings = function(n)
    local out = { "local t = {}" }
    for i = 1, n do
      out[#out + 1] = 't["k' .. i .. '"] = true'
    end
    out[#out + 1] = "return t"
    return out
  end,
  -- n distinct number constants
  numbers = function(n)
    local out = { "local t = {}" }
    for i = 1, n do
      out[#out + 1] = "t.x = " .. i .. ".5"
    end
    out[#out + 1] = "return t"
    return out
  end,
  -- one constructor of n distinct strings (an enum's values)
  constructor = function(n)
    local out = { "return {" }
    for i = 1, n do
      out[#out + 1] = '"v' .. i .. '",'
    end
    out[#out + 1] = "}"
    return out
  end,
  -- one constructor of n records (a struct's members)
  records = function(n)
    local out = { "return {" }
    for i = 1, n do
      out[#out + 1] = '{ name = "m' .. i .. '", required = true },'
    end
    out[#out + 1] = "}"
    return out
  end,
  -- n locals in one function
  locals = function(n)
    local out = {}
    for i = 1, n do
      out[#out + 1] = "local l" .. i .. " = " .. i
    end
    out[#out + 1] = "return l1"
    return out
  end,
  -- one closure with n upvalues
  upvalues = function(n)
    local out = { "local t = {}" }
    for i = 1, n do
      out[#out + 1] = "t[" .. i .. "] = " .. i
    end
    local body = { "return (function() local s = 0" }
    for i = 1, n do
      out[#out + 1] = "local u" .. i .. " = t[" .. i .. "]"
    end
    -- locals cap at 200, so upvalues past that are measured through nested functions
    for i = 1, n do
      body[#body + 1] = " s = s + u" .. i
    end
    body[#body + 1] = " return s end)()"
    out[#out + 1] = compat.concat(body, "\n")
    return out
  end,
  -- tables nested n deep
  nesting = function(n)
    return { "return " .. string.rep("{ ", n) .. string.rep("} ", n) }
  end,
  -- one long string of n bytes
  long_string = function(n)
    return { "return [[" .. string.rep("x", n) .. "]]" }
  end,
}

local PROBES = {
  { "strings", { 1000, 4000, 16000, 32000 } },
  { "strings", { 65536, 65537 }, slow = true },
  { "numbers", { 65536, 65537 }, slow = true },
  { "constructor", { 65537, 100000 }, slow = true },
  { "records", { 32000, 65537 }, slow = true },
  { "locals", { 200, 201 } },
  { "upvalues", { 60, 61, 199 } },
  { "nesting", { 100, 190, 199, 200, 250 } },
  { "long_string", { 16 * 1024 * 1024 } },
}

for _, probe in ipairs(PROBES) do
  if not (quick and probe.slow) then
    for _, n in ipairs(probe[2]) do
      local text = compat.concat(KINDS[probe[1]](n), "\n")
      local t0 = os.clock()
      local ok, fn, err = compat.pcall(compat.load, text, "=" .. probe[1])
      local ms = (os.clock() - t0) * 1000
      local result
      if ok and fn then
        result = string.format("ok %.0f ms (%d KB source)", ms, math.floor(#text / 1024))
      else
        result = "refused: " .. tostring(ok and err or fn)
      end
      print(string.format("%-7s %-12s %9d  %s", runtime, probe[1], n, result))
    end
  end
end
