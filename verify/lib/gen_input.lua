-- Minimal synthesized inputs for generated operations: every required member filled with
-- a placeholder of the right type, recursively (bounded depth, no recursion over data:
-- the depth is the schema's, capped at MAX_DEPTH).
--
--   local synth = require("verify.lib.gen_input")
--   local input, err = synth.input(op, registry)
local json = require("distilled.json")
local schema = require("distilled.schema")

local synth = {}

synth.MAX_DEPTH = 24

local SCALAR = {
  string = "x",
  number = 1,
  boolean = true,
  timestamp = "2024-01-01T00:00:00Z",
  blob = "bytes",
}

local value_for -- forward

local function struct_value(node, registry, depth)
  local out = {}
  for _, m in ipairs(node.members or {}) do
    if m.required then
      local v, err = value_for(m.schema, registry, depth + 1, m)
      if err then
        return nil, m.name .. ": " .. err
      end
      out[m.name] = v
    end
  end
  return out
end

function value_for(node, registry, depth, member)
  if depth > synth.MAX_DEPTH then
    return nil, "required members nest deeper than " .. synth.MAX_DEPTH
  end
  local resolved, err = schema.resolve(node, registry)
  if not resolved then
    return nil, tostring(err and err.message or err)
  end
  local t = resolved.t
  if member and member.bind == "label" then
    -- a label must be a non-empty path segment
    if t == "number" then
      return 1
    end
    if t == "enum" then
      return resolved.values[1]
    end
    return "p1"
  end
  if SCALAR[t] ~= nil then
    return SCALAR[t]
  elseif t == "unknown" then
    return json.object({})
  elseif t == "null" then
    return json.null
  elseif t == "enum" then
    return resolved.values[1]
  elseif t == "list" then
    local item, ierr = value_for(resolved.item, registry, depth + 1)
    if ierr then
      return nil, ierr
    end
    return json.array({ item })
  elseif t == "map" then
    return json.object({})
  elseif t == "union" then
    return value_for(resolved.arms[1], registry, depth + 1)
  elseif t == "struct" then
    return struct_value(resolved, registry, depth)
  end
  return nil, "no placeholder for node type " .. tostring(t)
end

--- synth.input(op, registry) -> input table | nil, message
function synth.input(op, registry)
  if op.input == nil then
    return {}
  end
  local node, err = schema.resolve(op.input, registry)
  if not node then
    return nil, tostring(err and err.message or err)
  end
  return struct_value(node, registry, 0)
end

synth.value = value_for

return synth
