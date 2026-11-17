-- Cloudflare conformance (task 19), the Lua side's helpers: synthesized inputs (Lua and
-- TS spellings at once), synthesized wire outputs, Lua -> TS renaming of decoded values,
-- and the comparison of a Lua outcome with Distilled's.
--
-- Distilled's Cloudflare SDK camelCases every member (gen/cloudflare.lua
-- ts_member_name); the Lua surface keeps wire names. Values are compared in TS names:
-- a Lua value is renamed by its schema (`to_ts`), so a member the generator mapped
-- wrongly still shows up as a difference.
--
-- Recursion here follows the schema, never the data, and is bounded (MAX_DEPTH).
local json = require("distilled.json")
local schema = require("distilled.schema")
local gen_cf = require("distilled.gen.cloudflare")

local lib = {}

lib.MAX_DEPTH = 3
lib.TOKEN = "cf-conform-token"
lib.BASE_URL = "https://api.cloudflare.com/client/v4"

local null = json.null
local ts_name = gen_cf.ts_member_name
lib.ts_name = ts_name

local function resolve(node, registry)
  return schema.resolve(node, registry)
end

-- result_info's keys in TS: protocol.ts camelizeKeys (shallow)
local function camelize(k)
  return (string.gsub(k, "_+([%w])", string.upper))
end

---------------------------------------------------------------------------------------
-- inputs
---------------------------------------------------------------------------------------

local function scalar_input(t, name, label)
  if label then
    return t == "number" and 1 or ("p-" .. name)
  end
  if t == "string" then
    return "s " .. name
  elseif t == "number" then
    return 7
  elseif t == "boolean" then
    return true
  elseif t == "timestamp" then
    return "2024-01-01T00:00:00Z"
  elseif t == "blob" then
    return "bytes-" .. name
  end
  return nil
end

local input_pair -- forward

local function struct_input(node, registry, depth)
  local lua, ts = {}, {}
  for _, m in ipairs(node.members or {}) do
    local bind = m.bind or "body"
    if (m.required or depth < lib.MAX_DEPTH) and not m.form_file and bind ~= "status" then
      local l, t = input_pair(m.schema, registry, depth + 1, m.name, bind == "label")
      if l ~= nil then
        lua[m.name] = l
        ts[ts_name(m.name)] = t
      end
    end
  end
  return lua, ts
end

function input_pair(node, registry, depth, name, label)
  local r = resolve(node, registry)
  if not r or depth > lib.MAX_DEPTH + 2 then
    return nil
  end
  local t = r.t
  local s = scalar_input(t, name or "v", label)
  if s ~= nil then
    return s, s
  elseif t == "enum" then
    return r.values[1], r.values[1]
  elseif t == "unknown" then
    return { opaque = 1 }, { opaque = 1 }
  elseif t == "list" then
    local l, x = input_pair(r.item, registry, depth + 1, name)
    if l == nil then
      return json.array({}), json.array({})
    end
    return json.array({ l }), json.array({ x })
  elseif t == "map" then
    local l, x = input_pair(r.value, registry, depth + 1, name)
    if l == nil then
      return json.object({}), json.object({})
    end
    return { k1 = l }, { k1 = x }
  elseif t == "union" then
    return input_pair(r.arms[1], registry, depth + 1, name)
  elseif t == "struct" then
    return struct_input(r, registry, depth)
  elseif t == "null" then
    return nil
  end
  return nil
end

--- lib.input(op, registry) -> lua_input, ts_input
function lib.input(op, registry)
  local node = resolve(op.input, registry)
  return struct_input(node, registry, 0)
end

---------------------------------------------------------------------------------------
-- outputs (wire JSON)
---------------------------------------------------------------------------------------

local wire_value -- forward

local function wire_struct(node, registry, depth, nulls, skip)
  local out = {}
  for _, m in ipairs(node.members or {}) do
    local bind = m.bind or "body"
    if bind == "body" and m.name ~= skip then
      if nulls and not m.required and m.nullable then
        out[m.wire or m.name] = null
      elseif m.required or depth < lib.MAX_DEPTH then
        local v = wire_value(m.schema, registry, depth + 1, m.name, nulls)
        if v ~= nil then
          out[m.wire or m.name] = v
        end
      end
    end
  end
  return json.object(out)
end

function wire_value(node, registry, depth, name, nulls)
  local r = resolve(node, registry)
  if not r or depth > lib.MAX_DEPTH + 2 then
    return nil
  end
  local t = r.t
  if t == "string" then
    return "o-" .. (name or "v")
  elseif t == "number" then
    return 3
  elseif t == "boolean" then
    return false
  elseif t == "timestamp" then
    return "2024-02-02T00:00:00Z"
  elseif t == "blob" then
    return nil
  elseif t == "enum" then
    return r.values[1]
  elseif t == "unknown" then
    return "opaque"
  elseif t == "list" then
    local v = wire_value(r.item, registry, depth + 1, name, nulls)
    return json.array(v ~= nil and { v } or {})
  elseif t == "map" then
    local v = wire_value(r.value, registry, depth + 1, name, nulls)
    return json.object(v ~= nil and { k1 = v } or {})
  elseif t == "union" then
    return wire_value(r.arms[1], registry, depth + 1, name, nulls)
  elseif t == "struct" then
    return wire_struct(r, registry, depth, nulls)
  end
  return nil
end
lib.wire_value = wire_value

--- lib.success_body(op, registry, opts) -> envelope text, response headers, items count
-- opts = { nulls, result_info }
function lib.success_body(op, registry, opts)
  opts = opts or {}
  local node = resolve(op.output, registry)
  local headers = { ["content-type"] = "application/json" }
  local payload
  if op.output_raw or node.t ~= "struct" then
    payload = wire_value(op.output, registry, 0, "result", opts.nulls)
  else
    local plan = schema.plan(node)
    local p = plan.by_bind.payload[1]
    if p then
      payload = wire_value(p.schema, registry, 0, p.name, opts.nulls)
    else
      -- a paginated output's result_info comes from the envelope (gen/cloudflare.lua)
      payload = wire_struct(node, registry, 0, opts.nulls, op.pagination and "result_info" or nil)
    end
    for _, m in ipairs(plan.by_bind.header) do
      local r = resolve(m.schema, registry)
      headers[string.lower(m.wire or m.name)] = (r and r.t == "number") and "5" or ("h-" .. m.name)
    end
  end
  local env = {
    success = true,
    errors = json.array({}),
    messages = json.array({}),
    result = payload == nil and null or payload,
  }
  if opts.result_info then
    env.result_info = opts.result_info
  end
  return json.encode(env), headers
end

---------------------------------------------------------------------------------------
-- Lua -> TS names
---------------------------------------------------------------------------------------

-- Distilled's decode renames per the schema, except where it has none: opaque values
-- and keys the schema does not model deep-rename by the op's T.KeyDictionary (the
-- model's metadata keyDictionary), and an opaque-cases union (every Cloudflare union)
-- renames its top-level keys by the dictionary, keeps only the active case's keys and
-- deep-renames their values by the dictionary (protocol-http.ts mapKeys,
-- mapKeysByDictionary). Lua keeps wire names and every key; this projects a Lua value
-- onto what Distilled returns.
local function by_dict(rename, v, depth)
  if type(v) ~= "table" or v == null or depth > 32 then
    return v
  end
  if json.is_array(v) then
    local out = json.array({})
    for i = 1, #v do
      out[i] = by_dict(rename, v[i], depth + 1)
    end
    return out
  end
  local out = json.object({})
  for k, x in pairs(v) do
    out[rename[k] or k] = by_dict(rename, x, depth + 1)
  end
  return out
end

local function union_cases(r, registry)
  local cases = {}
  for i, arm in ipairs(r.arms) do
    local a = resolve(arm, registry)
    local set, list = {}, {}
    if a and a.t == "struct" then
      for _, m in ipairs(a.members or {}) do
        local n = ts_name(m.name)
        set[n] = true
        list[#list + 1] = n
      end
    end
    cases[i] = { set = set, list = list }
  end
  return cases
end

local function to_ts(node, value, registry, rename, depth, info_member)
  if value == nil or value == null or depth > 16 then
    return value
  end
  local r = resolve(node, registry)
  if not r then
    return value
  end
  if r.t == "unknown" then
    return by_dict(rename, value, 0)
  elseif r.t == "union" then
    if type(value) ~= "table" or json.is_array(value) then
      return by_dict(rename, value, 0)
    end
    local obj = {}
    for k, v in pairs(value) do
      obj[rename[k] or k] = v
    end
    local cases = union_cases(r, registry)
    local best
    local disc = r.discriminator
    local tag = disc and obj[disc.key]
    if type(tag) == "string" then
      for i, v in ipairs(disc.values) do
        if v == tag and best == nil then
          best = { index = i }
        end
      end
    end
    if best == nil then
      local present = {}
      for k, v in pairs(obj) do
        if v ~= null then
          present[#present + 1] = k
        end
      end
      for i, c in ipairs(cases) do
        local matched, excess = 0, 0
        for _, k in ipairs(present) do
          if c.set[k] then
            matched = matched + 1
          else
            excess = excess + 1
          end
        end
        local score = matched - excess
        if
          matched > 0
          and (
            best == nil
            or score > best.score
            or (score == best.score and matched > best.matched)
          )
        then
          best = { index = i, score = score, matched = matched }
        end
      end
    end
    local out = json.object({})
    if best then
      for _, k in ipairs(cases[best.index].list) do
        if obj[k] ~= nil then
          out[k] = by_dict(rename, obj[k], 0)
        end
      end
    else
      for k, v in pairs(obj) do
        out[k] = by_dict(rename, v, 0)
      end
    end
    return out
  elseif r.t == "list" and type(value) == "table" then
    local out = json.array({})
    for i = 1, #value do
      out[i] = to_ts(r.item, value[i], registry, rename, depth + 1)
    end
    return out
  elseif r.t == "map" and type(value) == "table" then
    local out = json.object({})
    for k, v in pairs(value) do
      out[k] = to_ts(r.value, v, registry, rename, depth + 1)
    end
    return out
  elseif r.t == "struct" and type(value) == "table" and not json.is_array(value) then
    if #(r.members or {}) == 0 then
      return by_dict(rename, value, 0)
    end
    local out = json.object({})
    local known = {}
    for _, m in ipairs(r.members or {}) do
      known[m.name] = true
      local v = rawget(value, m.name)
      if v ~= nil then
        if m.name == "result_info" and info_member then
          -- camelizeKeys, shallow
          local info = {}
          if type(v) == "table" and v ~= null then
            for k, x in pairs(v) do
              info[camelize(k)] = x
            end
            out.resultInfo = info
          else
            out.resultInfo = v
          end
        else
          out[ts_name(m.name)] = to_ts(m.schema, v, registry, rename, depth + 1)
        end
      end
    end
    for k, v in pairs(value) do
      if not known[k] then
        out[rename[k] or k] = by_dict(rename, v, 0)
      end
    end
    return out
  end
  return value
end

local renames = {}
--- lib.rename_table(root, model) -> wire -> TS names, from the model's keyDictionary
function lib.rename_table(root, model)
  if renames[model] == nil then
    local f = assert(io.open(root .. "/models/cloudflare/" .. model .. ".json", "rb"))
    local doc = json.decode(f:read("*a"))
    f:close()
    local dict = doc.metadata and doc.metadata.keyDictionary or {}
    local t = {}
    for ts, wire in pairs(dict) do
      if type(wire) == "string" then
        t[wire] = ts
      elseif type(wire) == "table" then
        for _, w in ipairs(wire) do
          t[w] = ts
        end
      end
    end
    renames[model] = t
  end
  return renames[model]
end

--- lib.to_ts(op, value, registry, rename) -> the decoded Lua output in TS names
function lib.to_ts(op, value, registry, rename)
  return to_ts(op.output, value, registry, rename or {}, 0, op.pagination ~= nil)
end

---------------------------------------------------------------------------------------
-- comparison
---------------------------------------------------------------------------------------

-- a canonical JSON text of a value (sorted keys; empty tables as {})
function lib.canon(v)
  if v == nil then
    return "undefined"
  end
  local text = json.encode(v)
  return text or ("<" .. type(v) .. ">")
end

--- lib.query_pairs(url) -> sorted "k=v" list and the URL without its query
function lib.split_url(url)
  local base, q = string.match(url, "^([^?]*)%??(.*)$")
  local pairs_list = {}
  for pair in string.gmatch(q or "", "[^&]+") do
    pairs_list[#pairs_list + 1] = pair
  end
  table.sort(pairs_list)
  return base, pairs_list
end

return lib
