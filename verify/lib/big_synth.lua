-- Synthetic Smithy JSON models of any size, for the large-model specs and measurements
-- (task 18). Each operation has its own request, response, item and item list shapes,
-- and every operation shares one enum and one error, so the shapes have the structure of
-- the OpenAPI-converted models (per-operation shapes plus a few shared ones).
--
--   local synth = require("verify.lib.big_synth")
--   local text = synth.text({ ops = 200, members = 8, enum_values = 4, doc = 0 })
--   -- ops: operations; members: string members per request and item; enum_values: values
--   -- of the shared enum; doc: bytes of documentation on every member; prefix: shape
--   -- name prefix (long names: string.rep("Long", 10))
--   synth.provider() -> a provider spec table for it (module "syn")
local compat = require("distilled.compat")

local synth = {}

local function q(s)
  return '"' .. s .. '"'
end

function synth.text(opts)
  opts = opts or {}
  local n_ops = opts.ops or 10
  local n_members = opts.members or 4
  local n_values = opts.enum_values or 3
  local doc = opts.doc or 0
  local prefix = opts.prefix or ""
  local doc_trait = ""
  if doc > 0 then
    doc_trait = ', "smithy.api#documentation": ' .. q(string.rep("d", doc))
  end
  local out = {}
  local function add(s)
    out[#out + 1] = s
  end
  add('{ "smithy": "2.0", "metadata": {}, "shapes": {')
  local op_refs = {}
  for i = 1, n_ops do
    op_refs[i] = '{ "target": "syn.api#' .. prefix .. "Op" .. i .. '" }'
  end
  add(
    '"syn.api#Svc": { "type": "service", "version": "1", "operations": ['
      .. compat.concat(op_refs, ", ")
      .. '], "traits": { "smithy.api#title": "Synthetic API" } },'
  )
  local values = {}
  for v = 1, n_values do
    values[v] = q("V" .. v)
      .. ': { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": '
      .. q("v" .. v)
      .. " } }"
  end
  add('"syn.api#Kind": { "type": "enum", "members": { ' .. compat.concat(values, ", ") .. " } },")
  add(
    '"syn.api#NotFound": { "type": "structure", "members": { "message": { "target": '
      .. '"smithy.api#String" } }, "traits": { "smithy.api#error": "client", '
      .. '"smithy.api#httpError": 404 } },'
  )
  local function members(extra)
    local list = {}
    for m = 1, n_members do
      local required = (m == 1) and '"smithy.api#required": {}' or ""
      local traits = required .. doc_trait
      if string.sub(traits, 1, 2) == ", " then
        traits = string.sub(traits, 3)
      end
      list[#list + 1] = q("field" .. m)
        .. ': { "target": "smithy.api#String", "traits": { '
        .. traits
        .. " } }"
    end
    for _, e in ipairs(extra) do
      list[#list + 1] = e
    end
    return "{ " .. compat.concat(list, ", ") .. " }"
  end
  for i = 1, n_ops do
    local base = "syn.api#" .. prefix .. "Op" .. i
    add(
      q(base)
        .. ': { "type": "operation", "input": { "target": '
        .. q(base .. "Request")
        .. ' }, "output": { "target": '
        .. q(base .. "Response")
        .. ' }, "errors": [{ "target": "syn.api#NotFound" }], "traits": { "smithy.api#http": '
        .. '{ "method": "POST", "uri": "/things'
        .. i
        .. '/{id}", "code": 200 } } },'
    )
    add(q(base .. "Request") .. ': { "type": "structure", "members": ' .. members({
      '"id": { "target": "smithy.api#String", "traits": { "smithy.api#httpLabel": {}, '
        .. '"smithy.api#required": {} } }',
      '"items": { "target": ' .. q(base .. "ItemList") .. " }",
      '"kind": { "target": "syn.api#Kind" }',
    }) .. ' , "traits": { "smithy.api#input": {} } },')
    add(
      q(base .. "ItemList")
        .. ': { "type": "list", "member": { "target": '
        .. q(base .. "Item")
        .. " } },"
    )
    add(q(base .. "Item") .. ': { "type": "structure", "members": ' .. members({}) .. " },")
    add(
      q(base .. "Response")
        .. ': { "type": "structure", "members": { "thing": { "target": '
        .. q(base .. "Item")
        .. ' }, "kind": { "target": "syn.api#Kind" } } }'
        .. (i < n_ops and "," or "")
    )
  end
  add("} }")
  return compat.concat(out, "\n")
end

function synth.provider(overrides)
  local spec = {
    name = "syn",
    base_url = "https://syn.example.test",
    auth = { kind = "bearer", from = "api_key", env = "SYN_API_KEY" },
    unknown_tag = "UnknownSynError",
    parse_tag = "SynParseError",
    naming = { members = "wire" },
  }
  for k, v in pairs(overrides or {}) do
    spec[k] = v
  end
  return spec
end

return synth
