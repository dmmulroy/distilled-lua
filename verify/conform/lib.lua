-- Shared helpers for dl conform (Lua side): file I/O, the JSON case format, and the
-- mapping from a JSON input file to the value a Lua caller passes.
--
-- Case files are JSON so the same input reaches both languages:
--   JSON null           -> json.null in Lua, null in TypeScript
--   { "$secret": "v" }  -> distilled.secret("v") in Lua, Redacted.make("v") in TypeScript
-- Everything else is plain JSON in both.
local json = require("distilled.json")
local secret = require("distilled.secret")
local compat = require("distilled.compat")

local lib = {}

function lib.read(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local text = f:read("*a")
  f:close()
  return text
end

function lib.write(path, text)
  local f, err = io.open(path, "wb")
  if not f then
    error("conform: cannot write " .. path .. ": " .. tostring(err), 0)
  end
  f:write(text)
  f:close()
end

function lib.read_json(path)
  local text, err = lib.read(path)
  if not text then
    error("conform: cannot read " .. path .. ": " .. tostring(err), 0)
  end
  local value, derr = json.decode(text)
  if derr then
    error("conform: " .. path .. ": " .. tostring(derr), 0)
  end
  return value
end

-- One JSON value per line: a list stays diffable and a reader can stream it.
function lib.write_lines(path, list)
  local out = {}
  for i, v in ipairs(list) do
    out[i] = assert(json.encode(v))
  end
  out[#out + 1] = ""
  lib.write(path, compat.concat(out, "\n"))
end

function lib.read_lines(path)
  local text, err = lib.read(path)
  if not text then
    error("conform: cannot read " .. path .. ": " .. tostring(err), 0)
  end
  local list = {}
  for line in string.gmatch(text, "[^\n]+") do
    local v, derr = json.decode(line)
    if derr then
      error("conform: " .. path .. ": " .. tostring(derr), 0)
    end
    list[#list + 1] = v
  end
  return list
end

-- to_lua(value): JSON case value -> Lua input. Bounded by the case depth (cases are
-- generated at most a few levels deep), so plain recursion is safe on gopher-lua.
function lib.to_lua(v, depth)
  depth = depth or 0
  if depth > 60 then
    error("conform: case nests too deep", 0)
  end
  if type(v) ~= "table" or v == json.null then
    return v
  end
  if not json.is_array(v) and type(v["$secret"]) == "string" then
    local n = 0
    for _ in pairs(v) do
      n = n + 1
    end
    if n == 1 then
      return secret.wrap(v["$secret"])
    end
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = lib.to_lua(x, depth + 1)
  end
  if json.is_array(v) then
    return json.array(out)
  end
  return json.object(out)
end

-- FNV-1a over a string, as a seed: adding an operation does not move another's inputs.
function lib.seed_of(s)
  local h = 2166136261
  for i = 1, #s do
    h = (h + string.byte(s, i)) % 4294967296
    h = (h * 16777619) % 4294967296
  end
  return h % 2147483646 + 1
end

-- model op name -> the TypeScript export (lower camel case), as Distilled's generator.
function lib.ts_name(model_name)
  return string.lower(string.sub(model_name, 1, 1)) .. string.sub(model_name, 2)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, 64 do
  B64_INDEX[string.sub(B64, i, i)] = i - 1
end

--- lib.b64_decode(s) -> bytes (padding and unknown characters ignored)
function lib.b64_decode(s)
  local out, bits, nbits = {}, 0, 0
  for i = 1, #s do
    local v = B64_INDEX[string.sub(s, i, i)]
    if v then
      bits = bits * 64 + v
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        local p = 2 ^ nbits
        local byte = math.floor(bits / p)
        out[#out + 1] = string.char(byte)
        bits = bits - byte * p
      end
    end
  end
  return compat.concat(out)
end

--- lib.bytes_of(rec) -> the bytes of a { text } or { b64 } record, or nil
function lib.bytes_of(rec)
  if rec == nil then
    return nil
  end
  if rec.text ~= nil then
    return rec.text
  end
  if rec.b64 ~= nil then
    return lib.b64_decode(rec.b64)
  end
  return nil
end

return lib
