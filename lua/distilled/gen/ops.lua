-- Operations -> op descriptors (docs/interfaces.md, "Operation and service descriptors").
--
-- Ports generator.ts step 3 (pagination validation with `validatePaginated` and
-- `assertPaginationFields` from pagination.ts), step 6 (operation config), the
-- `distilled.retry#policy` reader (`retryPolicyOf`), and the telemetry compression
-- (`telemetryRules`, `telemetryLines`, the TELEMETRY const), with snake_case keys.
local emit = require("distilled.gen.emit")
local json = require("distilled.json")
local naming = require("distilled.gen.naming")
local shapes = require("distilled.gen.shapes")

local ops = {}

local T_RAW = "com.distilled.openapi#rawResponse"
local T_TEL_OP = "com.distilled.telemetry#operation"
local T_TEL_SERVICE = "com.distilled.telemetry#service"
local T_TEL_ATTRS = "com.distilled.telemetry#attributes"
local T_RETRY = "distilled.retry#policy"
local T_PAGINATED = "smithy.api#paginated"

local METHODS = { GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true }
METHODS.OPTIONS = true

---------------------------------------------------------------------------------------
-- http trait
---------------------------------------------------------------------------------------

--- ops.http(ctx, op) -> { method, uri, code, content_type, body_media_type } | nil, message
function ops.http(ctx, op)
  local http = op.def.traits and op.def.traits["smithy.api#http"]
  local where = op.id
  if type(http) ~= "table" then
    return nil, where .. ": no smithy.api#http trait (only HTTP bindings are supported)"
  end
  for _, k in ipairs(ctx.model:keys(http)) do
    if k ~= "method" and k ~= "uri" and k ~= "code" and k ~= "contentType" then
      if k ~= "bodyMediaType" then
        return nil, where .. ": smithy.api#http has unsupported key " .. k
      end
    end
  end
  if type(http.method) ~= "string" or not METHODS[string.upper(http.method)] then
    return nil, where .. ": smithy.api#http method " .. tostring(http.method) .. " is not supported"
  end
  if type(http.uri) ~= "string" or string.sub(http.uri, 1, 1) ~= "/" then
    return nil, where .. ": smithy.api#http uri must start with /"
  end
  if http.code ~= nil and type(http.code) ~= "number" then
    return nil, where .. ": smithy.api#http code must be a number"
  end
  local ct = http.contentType
  local trait_ct = op.def.traits["com.distilled.openapi#contentType"]
  if ct == nil then
    ct = trait_ct
  elseif trait_ct ~= nil and trait_ct ~= ct then
    return nil, where .. ": com.distilled.openapi#contentType disagrees with smithy.api#http"
  end
  if ct ~= nil and ct ~= "multipart" and ct ~= "form-urlencoded" then
    return nil, where .. ": content type " .. tostring(ct) .. " is not supported"
  end
  if http.bodyMediaType ~= nil and type(http.bodyMediaType) ~= "string" then
    return nil, where .. ": smithy.api#http bodyMediaType must be a string"
  end
  return {
    method = string.upper(http.method),
    uri = http.uri,
    code = http.code or 200,
    content_type = ct,
    body_media_type = http.bodyMediaType,
  }
end

--- ops.uri_labels(uri) -> list of { name, greedy } in URI order | nil, message
function ops.uri_labels(uri)
  local path = string.match(uri, "^([^?]*)")
  local out = {}
  for inner in string.gmatch(path, "{([^}]*)}") do
    local name, plus = string.match(inner, "^([A-Za-z_][A-Za-z0-9_%-]*)(%+?)$")
    if not name then
      return nil, "bad URI placeholder {" .. inner .. "} in " .. uri
    end
    out[#out + 1] = { name = name, greedy = plus == "+" }
  end
  return out
end

---------------------------------------------------------------------------------------
-- output
---------------------------------------------------------------------------------------

--- ops.output(ctx, op) -> { value = emit value, raw = bool, root = shape id | nil,
--   target = id (for types), type_target = id }
-- A structure whose only member carries rawResponse is a bare-payload response: the
-- output IS that member's value (`output_raw`). A paginated output keeps its member form
-- unless items is that sole member. A Blob target is binary (Neon's BinaryResponse).
function ops.output(ctx, op)
  local id = op.output
  local def = ctx.model.shapes[id]
  local members = ctx.model:members(def)
  if def.type == "structure" and #members == 1 and members[1].traits[T_RAW] ~= nil then
    local mem = members[1]
    local items_sole = op.pagination ~= nil
      and shapes.member_name(ctx, mem.name) == op.pagination_items_root
    if op.pagination == nil or items_sole then
      if mem.traits["com.distilled.openapi#nullable"] ~= nil then
        return nil, id .. ": a nullable rawResponse member is not supported"
      end
      local root = (not naming.is_prelude(mem.target)) and mem.target or nil
      return {
        value = shapes.ref(ctx, mem.target),
        raw = true,
        root = root,
        type_target = mem.target,
      }
    end
  end
  return {
    value = emit.call("S.ref", naming.local_name(id)),
    raw = false,
    root = id,
    type_target = id,
  }
end

---------------------------------------------------------------------------------------
-- pagination
---------------------------------------------------------------------------------------

local CORE_STRATEGY_FIELDS = {
  token = { "inputToken", "outputToken" },
  page = { "inputToken", "outputToken" },
  cursor = { "inputToken", "outputToken" },
  relay = { "inputToken", "outputToken" },
  keyset = { "inputToken", "outputToken", "items" },
  link = { "inputToken" },
  single = {},
}
ops.STRATEGY_FIELDS = CORE_STRATEGY_FIELDS

local TRAIT_KEYS = {
  mode = "mode",
  inputToken = "input_token",
  outputToken = "output_token",
  items = "items",
  pageSize = "page_size",
  hasNextPage = "has_next_page",
}

-- A dotted path of Smithy member names -> Lua member names, walking the shapes.
local function lua_path(ctx, start_id, path)
  local id = start_id
  local out = {}
  for segment in string.gmatch(path, "[^%.]+") do
    local def = id and ctx.model.shapes[id]
    if def and (def.type == "list" or def.type == "set") then
      id = def.member.target
      def = ctx.model.shapes[id]
    end
    local found
    if def and def.type == "structure" then
      for _, info in ipairs(shapes.members(ctx, def, id)) do
        if info.smithy == segment or info.name == segment then
          found = info
          break
        end
      end
    end
    if found then
      out[#out + 1] = found.name
      id = found.target
    else
      out[#out + 1] = segment
      id = nil
    end
  end
  return table.concat(out, ".")
end

--- ops.pagination(ctx, op) -> trait (snake_case, Lua names) | nil | false, message
function ops.pagination(ctx, op)
  local pg = op.def.traits and op.def.traits[T_PAGINATED]
  if pg == nil then
    return nil
  end
  local where = op.id
  if type(pg) ~= "table" then
    return false, where .. ": smithy.api#paginated must be an object"
  end
  for _, k in ipairs(ctx.model:keys(pg)) do
    if not TRAIT_KEYS[k] then
      return false, where .. ": smithy.api#paginated has unknown key " .. k
    end
  end
  local mode = pg.mode or "token"
  local fields = CORE_STRATEGY_FIELDS[mode]
  if not fields then
    return false, where .. ": smithy.api#paginated mode " .. tostring(mode) .. " is not known"
  end
  -- assertPaginationFields: a trait without a field its mode reads dies on first use.
  local missing = {}
  for _, f in ipairs(fields) do
    if type(pg[f]) ~= "string" or pg[f] == "" then
      missing[#missing + 1] = f
    end
  end
  if #missing > 0 then
    return false,
      where
        .. ": "
        .. mode
        .. " pagination needs "
        .. table.concat(missing, ", ")
        .. " in smithy.api#paginated. Patch the operation's trait."
  end
  -- validatePaginated: the token must be an input member and the items root an output
  -- member; Distilled quietly degrades such an operation to a plain one, we fail.
  local items = pg.items or ctx.provider.pagination.items_fallback
  local out = { mode = mode }
  if pg.inputToken then
    out.input_token = lua_path(ctx, op.input, pg.inputToken)
  end
  if pg.outputToken then
    out.output_token = lua_path(ctx, op.output, pg.outputToken)
  end
  if items and items ~= "" then
    out.items = lua_path(ctx, op.output, items)
  end
  if pg.pageSize then
    out.page_size = lua_path(ctx, op.input, pg.pageSize)
  end
  if pg.hasNextPage then
    out.has_next_page = lua_path(ctx, op.output, pg.hasNextPage)
  end
  local in_names, out_names = {}, {}
  for _, info in ipairs(shapes.members(ctx, ctx.model.shapes[op.input], op.input)) do
    in_names[info.name] = true
  end
  for _, info in ipairs(shapes.members(ctx, ctx.model.shapes[op.output], op.output)) do
    out_names[info.name] = true
  end
  if mode ~= "single" then
    local root = string.match(out.input_token or "", "^[^%.]+")
    if not root or not in_names[root] then
      return false,
        where .. ": pagination inputToken " .. tostring(pg.inputToken) .. " is not an input member"
    end
  end
  local items_root = string.match(out.items or "", "^[^%.]+")
  if not items_root or not out_names[items_root] then
    return false, where .. ": pagination items " .. tostring(items) .. " is not an output member"
  end
  if out.page_size and not in_names[string.match(out.page_size, "^[^%.]+")] then
    return false,
      where .. ": pagination pageSize " .. tostring(pg.pageSize) .. " is not an input member"
  end
  op.pagination_items_root = items_root
  return out
end

--- ops.item_type_target(ctx, output_id, items_path) -> shape id of one item | nil
-- paginatedItemTsType: walk the items path; a list at the end yields its member, and a
-- path that crossed a list yields the value it lands on.
function ops.item_type_target(ctx, output_id, items_path)
  if not items_path or items_path == "" then
    return output_id
  end
  local id = output_id
  local fanned = false
  for segment in string.gmatch(items_path, "[^%.]+") do
    local def = ctx.model.shapes[id]
    if def and (def.type == "list" or def.type == "set") then
      id = def.member.target
      def = ctx.model.shapes[id]
      fanned = true
    end
    if not def or def.type ~= "structure" then
      return nil
    end
    local found
    for _, info in ipairs(shapes.members(ctx, def, id)) do
      if info.name == segment then
        found = info
      end
    end
    if not found then
      return nil
    end
    id = found.target
  end
  local last = ctx.model.shapes[id]
  if last and (last.type == "list" or last.type == "set") then
    return last.member.target
  end
  return fanned and id or nil
end

---------------------------------------------------------------------------------------
-- retry
---------------------------------------------------------------------------------------

local RETRY_KEYS = {
  maxAttempts = "max_attempts",
  baseMs = "base_ms",
  throttlingBaseMs = "throttling_base_ms",
  capMs = "cap_ms",
  factor = "factor",
  longPoll = "long_poll",
}

-- retryPolicyOf: known keys, whole numbers, factor >= 1, longPoll a boolean.
local function retry_policy_of(ctx, value, where)
  if type(value) ~= "table" or value == json.null then
    return nil, where .. ": " .. T_RETRY .. " must be an object"
  end
  local out = {}
  for _, k in ipairs(ctx.model:keys(value)) do
    local n = value[k]
    local key = RETRY_KEYS[k]
    if not key then
      return nil, where .. ": " .. T_RETRY .. " has unknown key " .. k
    end
    if k == "longPoll" then
      if type(n) ~= "boolean" then
        return nil, where .. ": " .. T_RETRY .. ".longPoll must be a boolean"
      end
    elseif k == "factor" then
      if type(n) ~= "number" or not (n >= 1) then
        return nil, where .. ": " .. T_RETRY .. ".factor must be a number of at least 1"
      end
    elseif type(n) ~= "number" or n ~= math.floor(n) or n < (k == "maxAttempts" and 1 or 0) then
      return nil, where .. ": " .. T_RETRY .. "." .. k .. " must be a whole number"
    end
    out[key] = n
  end
  return out
end

--- ops.retry(ctx, op) -> table | nil (no policy) | false, message
function ops.retry(ctx, op)
  local merged, any = {}, false
  local svc = ctx.model.service
  if svc and svc.traits and svc.traits[T_RETRY] ~= nil then
    local p, err = retry_policy_of(ctx, svc.traits[T_RETRY], "service")
    if not p then
      return false, err
    end
    for k, v in pairs(p) do
      merged[k], any = v, true
    end
  end
  local own = op.def.traits and op.def.traits[T_RETRY]
  if own ~= nil then
    local p, err = retry_policy_of(ctx, own, op.id)
    if not p then
      return false, err
    end
    for k, v in pairs(p) do
      merged[k], any = v, true
    end
  end
  return any and merged or nil
end

---------------------------------------------------------------------------------------
-- telemetry
---------------------------------------------------------------------------------------

local TEL_OP_KEYS = { name = true, method = true, attributes = true, kind = true }
local UNSUPPORTED_TEL = {
  nameTemplate = "span name templates",
  inject = "message trace-context injection",
  extract = "message trace-context extraction",
  stream = "streamed-output spans",
  copy = "attribute copies",
}

-- telemetry.ts snakeCase: camelCase -> snake_case for the derived label attributes
local function tel_snake(s)
  s = string.gsub(s, "(%l)(%u)", "%1_%2")
  s = string.gsub(s, "(%u)(%u%l)", "%1_%2")
  s = string.gsub(s, "[-%s]+", "_")
  return string.lower(s)
end
ops.telemetry_snake_case = tel_snake

local function deep_copy_json(ctx, v)
  -- model values -> emit values: null becomes json.null, arrays become emit lists
  if v == json.null then
    ctx.uses_json = true
    return emit.raw("json.null")
  end
  if type(v) ~= "table" then
    return v
  end
  local keys = ctx.model.order[v]
  if keys then
    local out = {}
    for _, k in ipairs(keys) do
      out[k] = deep_copy_json(ctx, v[k])
    end
    return out
  end
  local list = {}
  for i = 1, #v do
    list[i] = deep_copy_json(ctx, v[i])
  end
  return emit.list(list)
end

local function same(a, b)
  return emit.inline(a) == emit.inline(b)
end

local function tally_most_common(values)
  local counts, order = {}, {}
  for _, v in ipairs(values) do
    if not counts[v] then
      order[#order + 1] = v
      counts[v] = 0
    end
    counts[v] = counts[v] + 1
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then
      return counts[a] > counts[b]
    end
    return a < b
  end)
  return order[1]
end

--- ops.telemetry_rules(ctx, selected) -> rules | nil, message
-- The rules most operations follow, so each op's span only holds what differs.
function ops.telemetry_rules(ctx, selected)
  local traced, with_template = 0, 0
  local shared, shared_order = {}, {}
  local prefixes, services, namespaces = {}, {}, {}
  local label_uses, label_order = {}, {}
  for _, op in ipairs(selected) do
    local trait = op.def.traits and op.def.traits[T_TEL_OP]
    if trait ~= nil then
      if type(trait) ~= "table" then
        return nil, op.id .. ": " .. T_TEL_OP .. " must be an object"
      end
      for _, k in ipairs(ctx.model:keys(trait)) do
        if UNSUPPORTED_TEL[k] then
          return nil,
            op.id
              .. ": "
              .. T_TEL_OP
              .. " "
              .. k
              .. " ("
              .. UNSUPPORTED_TEL[k]
              .. ")"
              .. " is not supported; generate with --no-telemetry"
        elseif not TEL_OP_KEYS[k] then
          return nil, op.id .. ": " .. T_TEL_OP .. " has unknown key " .. k
        end
      end
      local x = op.name
      traced = traced + 1
      local attrs = trait.attributes or {}
      if attrs["url.template"] ~= nil then
        with_template = with_template + 1
      end
      for _, key in ipairs(ctx.model:keys(attrs)) do
        if key ~= "url.template" then
          local pair = emit.inline({ key, deep_copy_json(ctx, attrs[key]) })
          if not shared[pair] then
            shared_order[#shared_order + 1] = pair
            shared[pair] = { key = key, value = attrs[key], count = 0 }
          end
          shared[pair].count = shared[pair].count + 1
        end
      end
      if type(trait.name) == "string" and string.sub(trait.name, -#x - 1) == "." .. x then
        prefixes[#prefixes + 1] = string.sub(trait.name, 1, -#x - 2)
      end
      if type(trait.method) == "string" and string.sub(trait.method, -#x - 1) == "/" .. x then
        services[#services + 1] = string.sub(trait.method, 1, -#x - 2)
      end
      for _, info in ipairs(shapes.members(ctx, ctx.model.shapes[op.input], op.input)) do
        if info.bind == "label" then
          local rules = info.traits[T_TEL_ATTRS]
          local tail = "." .. tel_snake(info.name)
          if
            type(rules) == "table"
            and #rules == 1
            and rules[1].transform == nil
            and type(rules[1].name) == "string"
            and string.sub(rules[1].name, -#tail) == tail
          then
            namespaces[#namespaces + 1] = string.sub(rules[1].name, 1, -#tail - 1)
          end
          if not label_uses[info.name] then
            label_uses[info.name] = {}
            label_order[#label_order + 1] = info.name
          end
          local key = ""
          if type(rules) == "table" and #rules == 1 and rules[1].transform == nil then
            key = rules[1].name
          end
          label_uses[info.name][key] = (label_uses[info.name][key] or 0) + 1
        end
      end
    end
  end
  local hoisted, hoisted_keys = {}, {}
  for _, pair in ipairs(shared_order) do
    local s = shared[pair]
    if s.count * 2 > traced and hoisted[s.key] == nil then
      hoisted[s.key] = s.value
      hoisted_keys[#hoisted_keys + 1] = s.key
    end
  end
  local labels = tally_most_common(namespaces)
  local label_names = {}
  if labels ~= nil then
    for _, prop in ipairs(label_order) do
      local uses = label_uses[prop]
      local total, best, best_n = 0, nil, -1
      local names = {}
      for k, n in pairs(uses) do
        total = total + n
        names[#names + 1] = k
      end
      table.sort(names)
      for _, k in ipairs(names) do
        if uses[k] > best_n then
          best, best_n = k, uses[k]
        end
      end
      local fallback = labels .. "." .. tel_snake(prop)
      if best ~= "" and best ~= fallback and best_n * 2 > total then
        label_names[prop] = best
      end
    end
  end
  return {
    traced = traced,
    prefix = tally_most_common(prefixes),
    service = tally_most_common(services),
    labels = labels,
    label_names = label_names,
    hoisted = hoisted,
    hoisted_keys = hoisted_keys,
    templates = with_template * 2 >= traced,
  }
end

local function rule_list(ctx, rules)
  return deep_copy_json(ctx, rules)
end

--- ops.service_telemetry(ctx, rules) -> emit value | nil | false, message
function ops.service_telemetry(ctx, rules)
  local svc = ctx.model.service
  local trait = svc and svc.traits and svc.traits[T_TEL_SERVICE]
  if trait == nil then
    trait = ctx.model.doc.metadata and ctx.model.doc.metadata[T_TEL_SERVICE]
  end
  if trait == nil then
    return nil
  end
  if type(trait) ~= "table" then
    return false, "service: " .. T_TEL_SERVICE .. " must be an object"
  end
  local out = {}
  for _, k in ipairs(ctx.model:keys(trait)) do
    local v = trait[k]
    if k == "system" then
      out.system = v
    elseif k == "responseHeaders" then
      out.response_headers = rule_list(ctx, v)
    elseif k == "attributes" then
      out.attributes = deep_copy_json(ctx, v)
    elseif k == "propagation" then
      if v ~= "w3c" then
        return false, "service: telemetry propagation " .. tostring(v) .. " is not supported"
      end
      out.propagate = "w3c"
    elseif k == "hosts" then
      return false, "service: telemetry host rules are not supported; use --no-telemetry"
    else
      return false, "service: " .. T_TEL_SERVICE .. " has unknown key " .. k
    end
  end
  if #rules.hoisted_keys > 0 then
    local attrs = out.attributes or {}
    for _, k in ipairs(rules.hoisted_keys) do
      attrs[k] = deep_copy_json(ctx, rules.hoisted[k])
    end
    out.attributes = attrs
  end
  out.prefix = rules.prefix
  out.service = rules.service
  out.labels = rules.labels
  if next(rules.label_names) then
    out.label_names = rules.label_names
  end
  if not rules.templates then
    out.templates = false
  end
  return out
end

--- ops.span(ctx, op, rules, http) -> emit value | nil | false, message
function ops.span(ctx, op, rules, http)
  local trait = op.def.traits and op.def.traits[T_TEL_OP]
  if trait == nil then
    return nil
  end
  local x = op.name
  local input_infos = shapes.members(ctx, ctx.model.shapes[op.input], op.input)
  local input, input_order = {}, {}
  for _, info in ipairs(input_infos) do
    local r = info.traits[T_TEL_ATTRS]
    if type(r) == "table" and #r > 0 then
      input[info.name] = r
      input_order[#input_order + 1] = info.name
    end
  end
  local output = {}
  local out_def = ctx.model.shapes[op.output]
  for _, info in ipairs(shapes.members(ctx, out_def, op.output)) do
    local r = info.traits[T_TEL_ATTRS]
    if type(r) == "table" and #r > 0 then
      output[info.name] = rule_list(ctx, r)
    end
  end
  local derived_template = rules.templates and string.match(http.uri, "^([^?]*)") or nil
  local own = {}
  local template_flag
  local attrs = trait.attributes or {}
  for _, k in ipairs(ctx.model:keys(attrs)) do
    if k ~= "url.template" then
      own[k] = deep_copy_json(ctx, attrs[k])
    end
  end
  local template = attrs["url.template"]
  if template == nil then
    if rules.templates then
      template_flag = false
    end
  elseif template ~= derived_template then
    own["url.template"] = template
  end
  for _, k in ipairs(rules.hoisted_keys) do
    if own[k] == nil then
      ctx.uses_json = true
      own[k] = emit.raw("json.null")
    elseif same(own[k], deep_copy_json(ctx, rules.hoisted[k])) then
      own[k] = nil
    end
  end
  local overrides = {}
  local derived = {}
  if rules.labels ~= nil then
    for _, info in ipairs(input_infos) do
      if info.bind == "label" then
        derived[info.name] = true
        local want = {
          { name = rules.label_names[info.name] or (rules.labels .. "." .. tel_snake(info.name)) },
        }
        local have = input[info.name]
        if not have or not same(deep_copy_json(ctx, have), emit.list(want)) then
          overrides[info.name] = have and rule_list(ctx, have) or emit.list({})
        end
      end
    end
  end
  for _, name in ipairs(input_order) do
    if not derived[name] then
      overrides[name] = rule_list(ctx, input[name])
    end
  end
  local span = { op = x }
  if template_flag == false then
    span.template = false
  end
  if trait.name ~= (rules.prefix and (rules.prefix .. "." .. x)) then
    span.name = trait.name
  end
  if trait.method ~= (rules.service and (rules.service .. "/" .. x)) then
    span.method = trait.method
  end
  if trait.kind ~= nil then
    span.kind = trait.kind
  end
  if next(own) then
    span.attributes = own
  end
  if next(overrides) then
    span.input = overrides
  end
  if next(output) then
    span.output = output
  end
  local count = 0
  for _ in pairs(span) do
    count = count + 1
  end
  if count == 1 then
    return x
  end
  return span
end

---------------------------------------------------------------------------------------
-- descriptor
---------------------------------------------------------------------------------------

--- ops.descriptor(ctx, op) -> emit value of the op descriptor
-- op has been prepared by gen/init.lua: http, output, pagination, retry, span, errors.
function ops.descriptor(ctx, op)
  return {
    name = op.name,
    method = op.http.method,
    uri = op.http.uri,
    code = op.http.code,
    content_type = op.http.content_type,
    body_media_type = op.http.body_media_type,
    input = emit.call("S.ref", naming.local_name(op.input)),
    output = op.out.value,
    output_raw = op.out.raw or nil,
    errors = emit.list(op.error_tags),
    pagination = op.pagination,
    retry = op.retry,
    span = op.span,
  }
end

return ops
