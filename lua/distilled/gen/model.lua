-- The Smithy JSON model: load, index, validate, reachability.
--
-- Ports the model-level passes of Distilled's generator: `collectOperations`,
-- `ensureNamedIo`, `inheritServiceErrors`, `collectOpErrorIds` (operations.ts),
-- `reachableFrom` (graph.ts), `booleanStringEnums` (boolean-string-enums.ts), plus the
-- checks the brief adds: every target exists, every trait id is known.
--
-- Every problem is collected as a message naming the shape; `model.load` fails with all
-- of them at once, so one run shows everything that is wrong.
local compat = require("distilled.compat")
local json = require("distilled.json")
local ordered = require("distilled.gen.json_ordered")
local naming = require("distilled.gen.naming")
local traits_table = require("distilled.gen.traits")

local model = {}

model.PRELUDE = {
  String = "string",
  Boolean = "boolean",
  Integer = "number",
  Long = "number",
  Short = "number",
  Byte = "number",
  Float = "number",
  Double = "number",
  BigInteger = "number",
  BigDecimal = "number",
  Timestamp = "timestamp",
  Blob = "blob",
  Document = "unknown",
  Unit = "unit",
  PrimitiveBoolean = "boolean",
  PrimitiveInteger = "number",
  PrimitiveLong = "number",
  PrimitiveShort = "number",
  PrimitiveByte = "number",
  PrimitiveFloat = "number",
  PrimitiveDouble = "number",
}

local SHAPE_TYPES = {
  service = true,
  operation = true,
  structure = true,
  union = true,
  list = true,
  set = true,
  map = true,
  enum = true,
  intEnum = true,
  -- simple shapes declared in the model itself (aliases of a prelude scalar)
  string = "string",
  boolean = "boolean",
  integer = "number",
  long = "number",
  short = "number",
  byte = "number",
  float = "number",
  double = "number",
  bigInteger = "number",
  bigDecimal = "number",
  timestamp = "timestamp",
  blob = "blob",
  document = "unknown",
}
model.SIMPLE_TYPES = {}
for k, v in pairs(SHAPE_TYPES) do
  if type(v) == "string" then
    model.SIMPLE_TYPES[k] = v
  end
end

---------------------------------------------------------------------------------------
-- hashing (FNV-1a, 32 bit, with float arithmetic only: no bitwise operators in 5.1)
---------------------------------------------------------------------------------------

local XOR8 = {}
for a = 0, 255 do
  XOR8[a] = {}
  for b = 0, 255 do
    local r, bit, x, y = 0, 1, a, b
    for _ = 1, 8 do
      if (x % 2) ~= (y % 2) then
        r = r + bit
      end
      x, y, bit = math.floor(x / 2), math.floor(y / 2), bit * 2
    end
    XOR8[a][b] = r
  end
end

--- model.hash(text) -> "fnv1a32:xxxxxxxx"
function model.hash(text)
  local h = 2166136261
  local byte = string.byte
  for i = 1, #text do
    local low = h % 256
    h = h - low + XOR8[low][byte(text, i)]
    -- h * 16777619 mod 2^32, split so every product stays below 2^53
    h = (h * 403 + (h % 256) * 16777216) % 4294967296
  end
  return string.format("fnv1a32:%08x", h)
end

---------------------------------------------------------------------------------------
-- loading
---------------------------------------------------------------------------------------

local Model = {}
Model.__index = Model

--- Model:keys(t) -> the keys of a decoded object in document order (sorted for others)
function Model:keys(t)
  local keys = self.order[t]
  if keys then
    return keys
  end
  local list = {}
  for k in pairs(t or {}) do
    list[#list + 1] = k
  end
  table.sort(list)
  return list
end

--- Model:members(def) -> { { name, target, traits }, ... } in declaration order
function Model:members(def)
  local out = {}
  if type(def) ~= "table" or type(def.members) ~= "table" then
    return out
  end
  for _, name in ipairs(self:keys(def.members)) do
    local m = def.members[name]
    out[#out + 1] = { name = name, target = m.target, traits = m.traits or {} }
  end
  return out
end

--- Model:shape(id) -> def | nil
function Model:shape(id)
  return self.shapes[id]
end

--- Model:scalar(id) -> prelude scalar kind ("string", "number", ...) or nil
-- Simple shapes declared in the model (`"type": "string"`) count as their scalar.
function Model:scalar(id)
  if naming.is_prelude(id) then
    return model.PRELUDE[naming.local_name(id)]
  end
  local def = self.shapes[id]
  if def then
    return model.SIMPLE_TYPES[def.type]
  end
  return nil
end

--- Model:deps(def) -> target ids of a structure/union/list/map
function Model:deps(def)
  local out = {}
  if not def then
    return out
  end
  if def.type == "structure" or def.type == "union" then
    for _, m in ipairs(self:members(def)) do
      out[#out + 1] = m.target
    end
  elseif def.type == "list" or def.type == "set" then
    out[1] = def.member and def.member.target
  elseif def.type == "map" then
    if def.key then
      out[#out + 1] = def.key.target
    end
    out[#out + 1] = def.value and def.value.target
  end
  return out
end

--- Model:reachable(roots) -> set of non-prelude shape ids reachable from roots
-- An explicit stack: recursive shapes and deep models must not grow the call stack.
function Model:reachable(roots)
  local seen = {}
  local stack = {}
  for _, r in ipairs(roots) do
    stack[#stack + 1] = r
  end
  while #stack > 0 do
    local id = stack[#stack]
    stack[#stack] = nil
    if id and not seen[id] and not naming.is_prelude(id) and self.shapes[id] then
      seen[id] = true
      for _, dep in ipairs(self:deps(self.shapes[id])) do
        stack[#stack + 1] = dep
      end
    end
  end
  return seen
end

local function new_object(m, t, keys)
  m.order[t] = keys or {}
  return t
end

-- ensureNamedIo: a Unit input or output becomes an empty named structure, so every
-- operation has a shape that can carry its traits.
--
-- The name can already be taken. By an operation (Mailchimp: GetSurvey's output is
-- GetSurveyResponse, and GetSurveyResponse is also an operation): Distilled overwrites the
-- map entry and so do we; operations are reached through m.operations, never through
-- shapes, and are not registry entries. By an empty structure: it is reused (ours, from an
-- earlier pass, or the model's own). Anything else is a problem: overwriting it, as
-- Distilled would, would change every member that targets it.
local function named_io(m, op, id, problems)
  local existing = m.shapes[id]
  if existing ~= nil and existing.type ~= "operation" then
    local empty = existing.type == "structure" and next(existing.members or {}) == nil
    if not empty then
      problems[#problems + 1] = op.id
        .. ": its Unit input or output needs the name "
        .. id
        .. ", which a "
        .. tostring(existing.type)
        .. " shape already has"
    end
    return id
  end
  m.shapes[id] = new_object(
    m,
    { type = "structure", members = new_object(m, {}) },
    { "type", "members" }
  )
  if existing == nil then
    m.ids[#m.ids + 1] = id
  end
  return id
end

local function ensure_named_io(m, op, problems)
  local def = op.def
  local input = def.input and def.input.target or "smithy.api#Unit"
  local output = def.output and def.output.target or "smithy.api#Unit"
  local ns = m.namespace
  if input == "smithy.api#Unit" then
    input = named_io(m, op, ns .. "#" .. op.name .. "Request", problems)
  end
  if output == "smithy.api#Unit" then
    output = named_io(m, op, ns .. "#" .. op.name .. "Response", problems)
  end
  op.input, op.output = input, output
end

-- inheritServiceErrors: the service's errors are appended to every operation's own list,
-- after its own errors and without duplicates.
local function inherit_service_errors(m)
  local common = {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "service" then
      for _, e in ipairs(def.errors or {}) do
        local dup = false
        for _, c in ipairs(common) do
          dup = dup or c == e.target
        end
        if not dup then
          common[#common + 1] = e.target
        end
      end
    end
  end
  for _, op in ipairs(m.operations) do
    local list = {}
    for _, e in ipairs(op.def.errors or {}) do
      list[#list + 1] = e.target
    end
    for _, c in ipairs(common) do
      local has = false
      for _, e in ipairs(list) do
        has = has or e == c
      end
      if not has then
        list[#list + 1] = c
      end
    end
    op.errors = list
  end
end

-- booleanStringEnums: request-only members of an enum whose values are exactly "true"
-- and "false" become booleans sent as their string spelling (`string_encoded`).
local function boolean_string_enums(m)
  local bool_enums = {}
  local any = false
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "enum" then
      local values = {}
      for _, mem in ipairs(m:members(def)) do
        values[#values + 1] = mem.traits["smithy.api#enumValue"]
      end
      if
        #values == 2
        and (values[1] == "true" or values[2] == "true")
        and (values[1] == "false" or values[2] == "false")
      then
        bool_enums[id] = true
        any = true
      end
    end
  end
  if not any then
    return
  end
  -- request-only: reached from an operation input (or an @input shape) and not from any
  -- output, error, @output/@error shape, or structure no request reaches.
  local req_roots, res_roots = {}, {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "operation" then
      req_roots[#req_roots + 1] = def.input and def.input.target
      res_roots[#res_roots + 1] = def.output and def.output.target
      for _, e in ipairs(def.errors or {}) do
        res_roots[#res_roots + 1] = e.target
      end
    else
      local tr = def.traits or {}
      if tr["smithy.api#input"] then
        req_roots[#req_roots + 1] = id
      end
      if tr["smithy.api#output"] or tr["smithy.api#error"] then
        res_roots[#res_roots + 1] = id
      end
    end
  end
  local from_req = m:reachable(req_roots)
  for _, id in ipairs(m.ids) do
    if m.shapes[id].type == "structure" and not from_req[id] then
      res_roots[#res_roots + 1] = id
    end
  end
  local from_res = m:reachable(res_roots)
  local request_only = {}
  for id in pairs(from_req) do
    if not from_res[id] then
      request_only[id] = true
    end
  end
  local bool_lists = {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "list" and bool_enums[def.member.target] and request_only[id] then
      bool_lists[id] = true
    end
  end
  local retarget = {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "structure" and request_only[id] then
      for _, name in ipairs(m:keys(def.members or {})) do
        local mem = def.members[name]
        local is_list = bool_lists[mem.target]
        if bool_enums[mem.target] or is_list then
          if is_list then
            retarget[mem.target] = true
          else
            mem.target = "smithy.api#Boolean"
          end
          if not mem.traits then
            mem.traits = new_object(m, {})
          end
          if mem.traits["distilled.protocols#stringEncoded"] == nil then
            local keys = m.order[mem.traits]
            if keys then
              keys[#keys + 1] = "distilled.protocols#stringEncoded"
            end
            mem.traits["distilled.protocols#stringEncoded"] = {}
          end
        end
      end
    end
  end
  for id in pairs(retarget) do
    m.shapes[id].member.target = "smithy.api#Boolean"
  end
end

---------------------------------------------------------------------------------------
-- validation
---------------------------------------------------------------------------------------

-- Every trait on every shape, member, list member and map key/value must be known
-- (gen/traits.lua). Unknown ids in guarded namespaces fail; others are warnings.
local function audit_traits(m, problems, warnings)
  local function check(where, traits)
    if type(traits) ~= "table" then
      return
    end
    for _, id in ipairs(m:keys(traits)) do
      local known = traits_table.lookup(id, m.is_aws)
      if not known then
        if traits_table.guarded(id) then
          problems[#problems + 1] = where
            .. ": unsupported trait "
            .. id
            .. " (the generator does not know it; add it to lua/distilled/gen/traits.lua"
            .. " with how it is handled)"
        else
          warnings[#warnings + 1] = where .. ": ignored unknown trait " .. id
        end
      elseif known.fail then
        problems[#problems + 1] = where .. ": unsupported trait " .. id .. " (" .. known.fail .. ")"
      end
    end
  end
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    check(id, def.traits)
    for _, mem in ipairs(m:members(def)) do
      check(id .. "$" .. mem.name, mem.traits)
    end
    if (def.type == "list" or def.type == "set") and def.member then
      check(id .. "$member", def.member.traits)
    end
    if def.type == "map" then
      check(id .. "$key", def.key and def.key.traits)
      check(id .. "$value", def.value and def.value.traits)
    end
  end
end

local function check_target(m, problems, where, target)
  if type(target) ~= "string" then
    problems[#problems + 1] = where .. ": has no target"
    return
  end
  if naming.is_prelude(target) then
    if model.PRELUDE[naming.local_name(target)] == nil then
      problems[#problems + 1] = where .. ": unknown prelude shape " .. target
    end
  elseif m.shapes[target] == nil then
    problems[#problems + 1] = where .. ": dangling target " .. target
  end
end

local function check_shapes(m, problems)
  local by_local = {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    -- AWS models group operations into resources (lifecycle and identifiers only)
    local aws_resource = m.is_aws and type(def) == "table" and def.type == "resource"
    if aws_resource then
      def = nil
    elseif type(def) ~= "table" or not SHAPE_TYPES[def.type] then
      problems[#problems + 1] = id .. ": unsupported shape type " .. tostring(def and def.type)
    else
      local name = naming.local_name(id)
      if by_local[name] and def.type ~= "service" then
        problems[#problems + 1] = id
          .. ": local name "
          .. name
          .. " is also used by "
          .. by_local[name]
          .. " (the registry is keyed by local name)"
      end
      by_local[name] = id
      if def.mixins and #def.mixins > 0 then
        problems[#problems + 1] = id .. ": mixins are not supported (flatten the model first)"
      end
      if def.type == "structure" or def.type == "union" then
        for _, mem in ipairs(m:members(def)) do
          check_target(m, problems, id .. "$" .. mem.name, mem.target)
        end
        if def.type == "union" and #m:members(def) == 0 then
          problems[#problems + 1] = id .. ": a union with no members"
        end
      elseif def.type == "list" or def.type == "set" then
        check_target(m, problems, id .. "$member", def.member and def.member.target)
      elseif def.type == "map" then
        check_target(m, problems, id .. "$value", def.value and def.value.target)
        if def.key then
          check_target(m, problems, id .. "$key", def.key.target)
          local kind = m:scalar(def.key.target)
          local kdef = m.shapes[def.key.target]
          if kind ~= "string" and not (kdef and kdef.type == "enum") then
            problems[#problems + 1] = id .. ": map keys must be strings, got " .. def.key.target
          end
        end
      elseif def.type == "enum" or def.type == "intEnum" then
        for _, mem in ipairs(m:members(def)) do
          local v = mem.traits["smithy.api#enumValue"]
          local want = def.type == "enum" and "string" or "number"
          if v ~= nil and type(v) ~= want then
            problems[#problems + 1] = id .. "$" .. mem.name .. ": enumValue must be a " .. want
          end
          if v == nil and def.type == "intEnum" then
            problems[#problems + 1] = id .. "$" .. mem.name .. ": intEnum member has no enumValue"
          end
        end
      elseif def.type == "operation" then
        if def.input then
          check_target(m, problems, id .. " input", def.input.target)
        end
        if def.output then
          check_target(m, problems, id .. " output", def.output.target)
        end
        for k, e in ipairs(def.errors or {}) do
          check_target(m, problems, id .. " errors[" .. k .. "]", e.target)
          local edef = m.shapes[e.target]
          -- AWS models list errors patched in without the trait (Distilled's patches:
          -- an empty RequestLimitExceeded, ec2's aws.codegen#errorTag shapes)
          if edef and not m.is_aws and not (edef.traits and edef.traits["smithy.api#error"]) then
            problems[#problems + 1] = id
              .. ": error "
              .. e.target
              .. " has no smithy.api#error trait"
          end
          if edef and edef.type ~= "structure" then
            problems[#problems + 1] = id .. ": error " .. e.target .. " is not a structure"
          end
        end
      elseif def.type == "service" then
        for k, o in ipairs(def.operations or {}) do
          check_target(m, problems, id .. " operations[" .. k .. "]", o.target)
        end
        for k, e in ipairs(def.errors or {}) do
          check_target(m, problems, id .. " errors[" .. k .. "]", e.target)
        end
        -- resources only group operations; every operation shape is collected anyway
        if def.resources and #def.resources > 0 and not m.is_aws then
          problems[#problems + 1] = id .. ": service resources are not supported"
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- public
---------------------------------------------------------------------------------------

--- model.from_text(text [, path]) -> Model | nil, message
function model.from_text(text, path)
  local doc, order = ordered.decode(text)
  if not doc then
    return nil, (path or "model") .. ": not valid JSON: " .. tostring(order)
  end
  if type(doc) ~= "table" or type(doc.shapes) ~= "table" then
    return nil, (path or "model") .. ": not a Smithy JSON model (no shapes object)"
  end
  local m = setmetatable({
    doc = doc,
    order = order,
    path = path,
    bytes = #text,
    hash = model.hash(text),
    shapes = doc.shapes,
    ids = {},
    warnings = {},
  }, Model)
  for _, id in ipairs(m:keys(doc.shapes)) do
    m.ids[#m.ids + 1] = id
  end
  local problems = {}
  m.is_aws = require("distilled.gen.aws").is_aws_model(doc)
  check_shapes(m, problems)
  audit_traits(m, problems, m.warnings)
  if #problems > 0 then
    return nil, compat.concat(problems, "\n")
  end

  -- the service (at most one)
  for _, id in ipairs(m.ids) do
    if m.shapes[id].type == "service" then
      if m.service_id then
        return nil, "the model has two services: " .. m.service_id .. " and " .. id
      end
      m.service_id = id
      m.service = m.shapes[id]
    end
  end

  -- operations, sorted by local name (Distilled's collectOperations)
  m.operations = {}
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "operation" then
      m.operations[#m.operations + 1] = { id = id, name = naming.local_name(id), def = def }
    end
  end
  table.sort(m.operations, function(a, b)
    return a.name < b.name
  end)
  if #m.operations == 0 then
    return nil, (path or "model") .. ": the model has no operations"
  end
  m.namespace = string.match(m.operations[1].id, "^(.-)#")

  boolean_string_enums(m)
  inherit_service_errors(m)
  for _, op in ipairs(m.operations) do
    ensure_named_io(m, op, problems)
  end
  if #problems > 0 then
    return nil, compat.concat(problems, "\n")
  end
  return m
end

--- model.load(path) -> Model | nil, message
function model.load(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "cannot read model: " .. tostring(err)
  end
  local text = f:read("*a")
  f:close()
  return model.from_text(text, path)
end

model.null = json.null

return model
