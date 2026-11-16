-- A JSON decoder for the generator that remembers object key order.
--
-- Smithy JSON relies on key order: structure members, union arms and enum values are
-- declared in order, and Distilled emits them in that order (`Object.entries`). Lua tables
-- have no order, so `distilled.json` cannot carry it. This decoder returns the document
-- plus a side table `order[object] = { key, ... }`.
--
-- Generator-only: it runs under lua and luajit, never in a generated client. Arrays are
-- plain lists; JSON null is `distilled.json.null`.
local json = require("distilled.json")
local compat = require("distilled.compat")

local M = {}

local byte, sub, find = string.byte, string.sub, string.find

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

--- M.decode(text) -> value, order | nil, message
function M.decode(text)
  local order = {}
  local pos = 1
  local function fail(what)
    local line = 1
    for _ in string.gmatch(sub(text, 1, pos), "\n") do
      line = line + 1
    end
    error({ json_error = what .. " at line " .. line .. " (byte " .. pos .. ")" }, 0)
  end
  local function skip()
    pos = find(text, "[^ \t\r\n]", pos) or (#text + 1)
  end
  local function str()
    -- pos is at the opening quote
    local parts = {}
    local i = pos + 1
    while true do
      local j = find(text, '["\\]', i)
      if not j then
        pos = i
        fail("unterminated string")
      end
      parts[#parts + 1] = sub(text, i, j - 1)
      if byte(text, j) == 34 then
        pos = j + 1
        return compat.concat(parts)
      end
      local e = sub(text, j + 1, j + 1)
      if e == "u" then
        local hex = sub(text, j + 2, j + 5)
        local cp = tonumber(hex, 16)
        if not cp or #hex ~= 4 then
          pos = j
          fail("bad \\u escape")
        end
        local next_i = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and sub(text, next_i, next_i + 1) == "\\u" then
          local lo = tonumber(sub(text, next_i + 2, next_i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            next_i = next_i + 6
          end
        end
        if cp >= 0xD800 and cp <= 0xDFFF then
          cp = 0xFFFD
        end
        parts[#parts + 1] = utf8_char(cp)
        i = next_i
      else
        local c = ESCAPES[e]
        if not c then
          pos = j
          fail("bad escape")
        end
        parts[#parts + 1] = c
        i = j + 2
      end
    end
  end

  -- Iterative parse with an explicit stack (no recursion over document depth).
  local stack = {}
  local function value_start()
    skip()
    local c = sub(text, pos, pos)
    if c == "{" then
      local t = {}
      order[t] = {}
      pos = pos + 1
      return t, "object"
    elseif c == "[" then
      local t = {}
      pos = pos + 1
      return t, "array"
    elseif c == '"' then
      return str()
    elseif c == "t" and sub(text, pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif c == "f" and sub(text, pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif c == "n" and sub(text, pos, pos + 3) == "null" then
      pos = pos + 4
      return json.null
    else
      local s, e = find(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not s then
        fail("unexpected character " .. string.format("%q", c))
      end
      local n = tonumber(sub(text, s, e))
      if n == nil then
        fail("bad number")
      end
      pos = e + 1
      return n
    end
  end

  local root
  local ok, err = compat.pcall(function()
    local v, kind = value_start()
    if kind then
      stack[1] = { t = v, kind = kind, first = true }
    else
      root = v
    end
    if kind then
      root = v
    end
    while #stack > 0 do
      local top = stack[#stack]
      skip()
      local c = sub(text, pos, pos)
      local closer = top.kind == "object" and "}" or "]"
      if c == closer then
        pos = pos + 1
        stack[#stack] = nil
      else
        if not top.first then
          if c ~= "," then
            fail("expected , or " .. closer)
          end
          pos = pos + 1
          skip()
        end
        top.first = false
        local key
        if top.kind == "object" then
          if sub(text, pos, pos) ~= '"' then
            fail("expected a key")
          end
          key = str()
          skip()
          if sub(text, pos, pos) ~= ":" then
            fail("expected :")
          end
          pos = pos + 1
        end
        local v, kind = value_start()
        if top.kind == "object" then
          if top.t[key] == nil then
            local keys = order[top.t]
            keys[#keys + 1] = key
          end
          top.t[key] = v
        else
          top.t[#top.t + 1] = v
        end
        if kind then
          stack[#stack + 1] = { t = v, kind = kind, first = true }
        end
      end
    end
    skip()
    if pos <= #text then
      fail("trailing characters")
    end
  end)
  if not ok then
    if type(err) == "table" and err.json_error then
      return nil, err.json_error
    end
    return nil, tostring(err)
  end
  return root, order
end

return M
