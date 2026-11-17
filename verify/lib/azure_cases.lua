-- Writes spec/fixtures/azure/cases.json: the request cases of the Azure conformance check
-- (verify/lib/azure_ref.mjs runs them through Distilled, spec/azure_conform_spec.lua
-- through the Lua clients). Deterministic: the same clients give the same file.
--
--   luajit verify/lib/azure_cases.lua <root> <out.json>
--
-- Per model (clients/azure/<model>/service.lua), operations in name order: the first of
-- each HTTP method, the first with a greedy label, the first with a header member, the
-- first with a query member and the first with a payload member. Each input has every
-- required member (verify/lib/gen_input.lua placeholders) and every optional top-level
-- scalar member, with values that need encoding (spaces, slashes, quotes, `$`). Every
-- other case leaves subscriptionId out, so the client's subscription_id fills it.
local root, out = arg[1], arg[2]
assert(root and out, "usage: azure_cases.lua <root> <out.json>")
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local json = require("distilled.json")
local schema = require("distilled.schema")
local synth = require("verify.lib.gen_input")

local index = require("azure")

local SCALAR_VALUE = {
  string = "it's a b/c $x",
  number = 7,
  boolean = true,
  timestamp = "2024-01-02T03:04:05Z",
}

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do
    list[#list + 1] = k
  end
  table.sort(list)
  return list
end

local function members_of(op, registry)
  local node = op.input and schema.resolve(op.input, registry)
  return node and node.members or {}
end

local function has_bind(op, registry, bind)
  for _, m in ipairs(members_of(op, registry)) do
    if m.bind == bind or (bind == "greedy" and m.greedy) then
      return true
    end
  end
  return false
end

local n_case = 0
local function input_for(op, registry)
  local input, err = synth.input(op, registry)
  if not input then
    return nil, err
  end
  for _, m in ipairs(members_of(op, registry)) do
    local node = schema.resolve(m.schema, registry)
    local t = node and node.t
    if m.bind == "label" then
      if m.greedy then
        input[m.name] = "/subscriptions/sub-9/resourceGroups/rg 1"
      elseif t == "string" then
        input[m.name] = "n " .. m.name .. "/1"
      end
    elseif not m.required and SCALAR_VALUE[t] ~= nil and m.bind ~= "payload" then
      input[m.name] = SCALAR_VALUE[t]
    elseif not m.required and t == "enum" and m.bind ~= nil then
      input[m.name] = node.values[#node.values]
    end
  end
  n_case = n_case + 1
  if input.subscriptionId ~= nil and n_case % 2 == 0 then
    input.subscriptionId = nil
  end
  return input
end

local cases = {}
for _, model in ipairs(index.services) do
  local service = require("azure." .. model .. ".service")
  local registry = service.shapes
  local picked, why = {}, {}
  local function pick(name, reason)
    if not picked[name] then
      picked[name] = true
      why[#why + 1] = { name = name, reason = reason }
    end
  end
  local seen = {}
  for _, name in ipairs(sorted_keys(service.ops)) do
    local op = service.ops[name]
    local checks = {
      { "method " .. op.method, true },
      { "greedy", has_bind(op, registry, "greedy") },
      { "header", has_bind(op, registry, "header") },
      { "query", has_bind(op, registry, "query") },
      { "payload", has_bind(op, registry, "payload") },
    }
    for _, c in ipairs(checks) do
      if c[2] and not seen[c[1]] then
        seen[c[1]] = true
        pick(name, c[1])
      end
    end
  end
  for _, w in ipairs(why) do
    local op = service.ops[w.name]
    local input, err = input_for(op, registry)
    if input then
      cases[#cases + 1] = {
        id = model .. "." .. w.name,
        model = model,
        method = w.name,
        ts = op.name,
        why = w.reason,
        input = input,
      }
    else
      io.stderr:write("skip " .. model .. "." .. w.name .. ": " .. tostring(err) .. "\n")
    end
  end
end

local f = assert(io.open(out, "wb"))
f:write("[\n")
for i, c in ipairs(cases) do
  f:write(json.encode(c), i < #cases and ",\n" or "\n")
end
f:write("]\n")
f:close()
print("wrote " .. out .. ": " .. #cases .. " cases")
