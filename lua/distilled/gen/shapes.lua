-- Smithy shapes -> schema node values (docs/interfaces.md, "Schema nodes").
--
-- Ports the shape half of Distilled's generator (`generator.ts` steps 2 and 5,
-- `members.ts`): member naming with collision fallback, the binding cascade label ->
-- query -> header -> payload -> body, wire names (`smithyWireName`), required (with the
-- `@default` rule for response-only shapes and the paginated items rule), nullable
-- (members, and list items / map values as S.nullable nodes), sensitive, string_encoded,
-- open structures, enums, lists, maps and unions with their discriminator
-- (`unionDiscriminator`).
--
-- Values returned here are emit values (gen/emit.lua): plain tables with `emit.raw` for
-- the shared scalar nodes and `emit.call("S.ref", name)` for references. Every named
-- shape is a registry entry keyed by its local name and referenced through `S.ref`, so
-- recursive shapes need nothing special.
local emit = require("distilled.gen.emit")
local naming = require("distilled.gen.naming")

local shapes = {}

local T_NULLABLE = "com.distilled.openapi#nullable"
local T_SENSITIVE = "smithy.api#sensitive"
local T_OPEN = "com.distilled.openapi#additionalProperties"
local T_STRING_ENCODED = "distilled.protocols#stringEncoded"
local T_DEFAULT = "smithy.api#default"

local SCALAR_CODE = {
  string = "S.string",
  number = "S.number",
  boolean = "S.boolean",
  timestamp = "S.timestamp",
  blob = "S.blob",
  unknown = "S.unknown",
}
shapes.SCALAR_CODE = SCALAR_CODE

--- shapes.binding(traits) -> "label" | "query" | "header" | "status" | "payload" | "body"
-- Distilled's cascade (bindingOf): label, query, header, provider bindings, raw body
-- (httpPayload), body. httpResponseCode is Smithy's status binding (none in Neon).
function shapes.binding(traits)
  if traits["smithy.api#httpLabel"] ~= nil then
    return "label"
  elseif traits["smithy.api#httpQuery"] ~= nil then
    return "query"
  elseif traits["smithy.api#httpHeader"] ~= nil then
    return "header"
  elseif traits["smithy.api#httpResponseCode"] ~= nil then
    return "status"
  elseif traits["smithy.api#httpPayload"] ~= nil then
    return "payload"
  end
  return "body"
end

-- smithyWireName: labels use the member name (the URI placeholder), query and header the
-- trait's non-empty string, everything else jsonName.
local function wire_name(traits, smithy_name, bind)
  if bind == "label" or bind == "status" or bind == "payload" then
    return smithy_name
  elseif bind == "query" then
    local v = traits["smithy.api#httpQuery"]
    return (type(v) == "string" and v ~= "") and v or smithy_name
  elseif bind == "header" then
    local v = traits["smithy.api#httpHeader"]
    return (type(v) == "string" and v ~= "") and v or smithy_name
  end
  local j = traits["smithy.api#jsonName"]
  return type(j) == "string" and j or smithy_name
end

--- shapes.member_name(ctx, smithy_name) -> the key in the user's Lua table
function shapes.member_name(ctx, smithy_name)
  if ctx.provider.naming.members == "snake_case" then
    return naming.snake_case(smithy_name, ctx.words)
  end
  return smithy_name
end

--- shapes.members(ctx, def, owner_id) -> list of member infos (cached per def)
-- info = { name, smithy, wire, bind, target, required, nullable, sensitive,
--          string_encoded, greedy, doc, traits }
function shapes.members(ctx, def, owner_id)
  ctx.member_cache = ctx.member_cache or {}
  local key = def
  local cached = ctx.member_cache[key]
  if cached and cached.owner == owner_id then
    return cached.list
  end
  local m = ctx.model
  local list = {}
  local used = {}
  local greedy = owner_id and ctx.greedy and ctx.greedy[owner_id] or {}
  local items_root = owner_id and ctx.items_root and ctx.items_root[owner_id]
  local response_only = owner_id ~= nil
    and ctx.request_reachable ~= nil
    and not ctx.request_reachable[owner_id]
  for _, mem in ipairs(m:members(def)) do
    local traits = mem.traits
    -- memberBases: a clashing Lua name falls back to the Smithy name, then a suffix
    local lua_name = shapes.member_name(ctx, mem.name)
    if used[lua_name] then
      lua_name = mem.name
    end
    local k = 2
    while used[lua_name] do
      lua_name = shapes.member_name(ctx, mem.name) .. k
      k = k + 1
    end
    used[lua_name] = true
    local bind = shapes.binding(traits)
    local target_def = m.shapes[mem.target]
    local info = {
      name = lua_name,
      smithy = mem.name,
      bind = bind,
      wire = wire_name(traits, mem.name, bind),
      target = mem.target,
      required = traits["smithy.api#required"] ~= nil
        or (traits[T_DEFAULT] ~= nil and response_only)
        or (items_root ~= nil and items_root == lua_name),
      nullable = traits[T_NULLABLE] ~= nil,
      sensitive = traits[T_SENSITIVE] ~= nil
        or (
          target_def ~= nil
          and target_def.traits ~= nil
          and target_def.traits[T_SENSITIVE] ~= nil
        ),
      string_encoded = traits[T_STRING_ENCODED] ~= nil,
      greedy = bind == "label" and greedy[mem.name] == true,
      doc = traits["smithy.api#documentation"],
      traits = traits,
    }
    list[#list + 1] = info
  end
  ctx.member_cache[key] = { owner = owner_id, list = list }
  return list
end

--- shapes.ref(ctx, target) -> emit value for a reference to target
function shapes.ref(ctx, target)
  local kind = ctx.model:scalar(target)
  if naming.is_prelude(target) then
    if kind == "unit" then
      return { t = "struct", members = emit.list({}) }
    end
    return emit.raw(SCALAR_CODE[kind])
  end
  return emit.call("S.ref", naming.local_name(target))
end

-- The sole value of a one-value enum, if target is one (soleEnumValue).
local function sole_enum_value(ctx, target)
  local def = ctx.model.shapes[target]
  if not def or def.type ~= "enum" then
    return nil
  end
  local values = shapes.enum_values(ctx, def)
  if #values == 1 and type(values[1]) == "string" then
    return values[1]
  end
  return nil
end

--- shapes.enum_values(ctx, def) -> values in declaration order
-- Smithy: an enum member without enumValue has its member name as the value.
function shapes.enum_values(ctx, def)
  local values = {}
  for _, mem in ipairs(ctx.model:members(def)) do
    local v = mem.traits["smithy.api#enumValue"]
    if v == nil and def.type == "enum" then
      v = mem.name
    end
    values[#values + 1] = v
  end
  return values
end

--- shapes.union_arms(ctx, id, def) -> arm target ids (an arm targeting the union itself
-- carries nothing and is dropped, as Distilled does)
function shapes.union_arms(ctx, id, def)
  local arms = {}
  for _, mem in ipairs(ctx.model:members(def)) do
    if mem.target ~= id then
      arms[#arms + 1] = mem.target
    end
  end
  return arms
end

--- shapes.union_discriminator(ctx, arm_targets) -> { key, values } | nil
-- The member every arm pins to a different literal (unionDiscriminator): every arm a
-- structure with at least one one-value enum member; the first such key (in the first
-- arm's order) present in all arms with distinct values wins.
function shapes.union_discriminator(ctx, arms)
  if #arms < 2 then
    return nil
  end
  local per_arm = {}
  for i, target in ipairs(arms) do
    local def = ctx.model.shapes[target]
    if not def or def.type ~= "structure" then
      return nil
    end
    local tags, order = {}, {}
    for _, info in ipairs(shapes.members(ctx, def, target)) do
      local v = sole_enum_value(ctx, info.target)
      if v ~= nil then
        tags[info.name] = v
        order[#order + 1] = info.name
      end
    end
    if #order == 0 then
      return nil
    end
    per_arm[i] = { tags = tags, order = order }
  end
  for _, key in ipairs(per_arm[1].order) do
    local values, seen, ok = {}, {}, true
    for i = 1, #arms do
      local v = per_arm[i].tags[key]
      if v == nil or seen[v] then
        ok = false
        break
      end
      seen[v] = true
      values[i] = v
    end
    if ok then
      return { key = key, values = emit.list(values) }
    end
  end
  return nil
end

--- shapes.member_value(ctx, info) -> emit value for a member table
function shapes.member_value(ctx, info)
  local v = { name = info.name, schema = shapes.ref(ctx, info.target) }
  if info.wire ~= info.name then
    v.wire = info.wire
  end
  if info.bind ~= "body" then
    v.bind = info.bind
  end
  if info.required then
    v.required = true
  end
  if info.nullable then
    v.nullable = true
  end
  if info.sensitive then
    v.sensitive = true
  end
  if info.greedy then
    v.greedy = true
  end
  if info.string_encoded then
    v.string_encoded = true
  end
  return v
end

--- shapes.element(ctx, member_def) -> emit value for a list item or a map value
-- The element takes a structure member's traits (Distilled's list/map branch): sensitive
-- wraps it in S.sensitive, nullable (a sparse list or map) in S.nullable, Distilled's
-- `S.NullOr(item)`.
function shapes.element(ctx, mem)
  local traits = mem.traits or {}
  local node = shapes.ref(ctx, mem.target)
  if traits[T_SENSITIVE] ~= nil then
    node = emit.call("S.sensitive", node)
  end
  if traits[T_NULLABLE] ~= nil then
    node = emit.call("S.nullable", node)
  end
  return node
end

--- shapes.node(ctx, id) -> emit value for the registry entry of a named shape | nil, message
function shapes.node(ctx, id)
  local m = ctx.model
  local def = m.shapes[id]
  local name = naming.local_name(id)
  local node
  if def.type == "structure" then
    local members = {}
    for _, info in ipairs(shapes.members(ctx, def, id)) do
      members[#members + 1] = shapes.member_value(ctx, info)
    end
    node = { t = "struct", name = name, members = emit.list(members) }
    if def.traits and def.traits[T_OPEN] ~= nil then
      node.open = true
    end
  elseif def.type == "list" or def.type == "set" then
    node = { t = "list", item = shapes.element(ctx, def.member) }
  elseif def.type == "map" then
    node = { t = "map", value = shapes.element(ctx, def.value) }
  elseif def.type == "enum" or def.type == "intEnum" then
    local values = shapes.enum_values(ctx, def)
    if #values == 0 then
      return nil, id .. ": an enum with no values"
    end
    node = {
      t = "enum",
      values = emit.list(values),
      base = def.type == "enum" and "string" or "number",
    }
  elseif def.type == "union" then
    local arms = shapes.union_arms(ctx, id, def)
    if #arms == 0 then
      return nil, id .. ": a union whose only arm is itself"
    end
    local refs = {}
    for i, target in ipairs(arms) do
      refs[i] = shapes.ref(ctx, target)
    end
    node =
      { t = "union", arms = emit.list(refs), discriminator = shapes.union_discriminator(ctx, arms) }
  else
    -- a simple shape declared in the model (`"type": "string"`): its scalar node
    local kind = require("distilled.gen.model").SIMPLE_TYPES[def.type]
    if not kind then
      return nil, id .. ": cannot make a schema node from a " .. tostring(def.type) .. " shape"
    end
    node = { t = kind }
  end
  if def.traits and def.traits[T_SENSITIVE] ~= nil then
    node.sensitive = true
  end
  return node
end

return shapes
