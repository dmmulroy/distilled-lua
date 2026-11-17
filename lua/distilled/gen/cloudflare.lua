-- Cloudflare model support: what Distilled's packages/cloudflare/scripts/generate.ts
-- (the Cloudflare SdkSpec) tells its generator, for models whose service carries
-- `com.cloudflare.protocols#v4Json`.
--
-- `cloudflare.prepare(ctx)` rewrites the loaded model in memory into the vocabulary the
-- generic generator already speaks, then installs a few hooks on ctx:
--
--   com.cloudflare.protocols#...   becomes / does
--   nullable                       com.distilled.openapi#nullable (SdkSpec.nullableTrait)
--   errorMatchers                  com.distilled.openapi#errorMatchers (errorMatchersTrait)
--   envelopePayload                smithy.api#httpPayload (bind = "payload": the member
--                                  receives the envelope's whole `result`); as the sole
--                                  member of a non-paginated output also rawResponse
--                                  (Distilled's rootPipe EnvelopePayloadRoot: the output
--                                  IS the payload)
--   binaryResponseBody             httpPayload on a Blob (the raw body bytes)
--   deepQuery                      httpQuery under the trait's wire name, style = "deep"
--   formDataFile                   member field form_file = true (the protocol sends
--                                  each file as a part named after its filename)
--   host                           op.host, the per-operation origin; its {labels} need
--                                  no placeholder in the URI
--   jurisdiction                   op.jurisdiction = true (cf-r2-jurisdiction header)
--   verbatimPayload, keyDictionary nothing: Lua names are wire names, so there is no
--                                  camelCase key mapping to switch off
--
-- plus the SdkSpec settings: optionalsNullable (every optional body member of a
-- response-reachable shape is nullable), the `envelope` pagination profile (paginated
-- outputs get a `result_info` member, page mode needs only inputToken, the strategy is
-- Cloudflare's), and the key dictionary's fallback wire names for top-level output
-- members (op.fallback_wire, see protocol/cloudflare.lua).
--
-- Member names stay as the wire spells them (the plan's naming rule); Distilled's TS
-- surface camelCases them, and the model's pagination traits are written in those TS
-- names (`perPage`, `resultInfo.page`), so they are translated back here.
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local naming = require("distilled.gen.naming")

local cloudflare = {}

local P = "com.cloudflare.protocols#"
cloudflare.TRAITS = {
  v4 = P .. "v4Json",
  envelope = P .. "envelopePayload",
  nullable = P .. "nullable",
  error_matchers = P .. "errorMatchers",
  form_file = P .. "formDataFile",
  binary = P .. "binaryResponseBody",
  key_dictionary = P .. "keyDictionary",
  deep_query = P .. "deepQuery",
  host = P .. "host",
  jurisdiction = P .. "jurisdiction",
  verbatim = P .. "verbatimPayload",
}
local T = cloudflare.TRAITS

local NULLABLE = "com.distilled.openapi#nullable"
local MATCHERS = "com.distilled.openapi#errorMatchers"
local RAW = "com.distilled.openapi#rawResponse"
local PAYLOAD = "smithy.api#httpPayload"
local QUERY = "smithy.api#httpQuery"
local DOC = "smithy.api#documentation"
local PAGINATED = "smithy.api#paginated"

-- the member the envelope's `result_info` lands in (Distilled: resultInfo)
cloudflare.RESULT_INFO = "result_info"
cloudflare.DEFAULT_BASE_URL = "https://api.cloudflare.com/client/v4"

cloudflare.PROTOCOL_MODULE = "distilled.protocol.cloudflare"

--- cloudflare.applies(m [, spec]) -> boolean: the model speaks the v4 envelope protocol
-- (its service says so), or the provider spec names the Cloudflare protocol (`protocol =
-- "distilled.protocol.cloudflare"`: k2, a hand-written model, has no service shape).
function cloudflare.applies(m, spec)
  if spec and spec.protocol == cloudflare.PROTOCOL_MODULE then
    return true
  end
  local svc = m and m.service
  return svc ~= nil and svc.traits ~= nil and svc.traits[T.v4] ~= nil
end

-- JavaScript reserved words lowerFirst leaves capitalised (dev/codegen/naming.ts RESERVED)
local RESERVED = {}
for w in
  string.gmatch(
    "break case catch class const continue debugger default delete do else enum export"
      .. " extends false finally for function if import in instanceof new null return super"
      .. " switch this throw true try typeof var void while with yield let static"
      .. " implements interface package private protected public await",
    "%S+"
  )
do
  RESERVED[w] = true
end

--- cloudflare.ts_member_name(name) -> Distilled's TS name of a member (generate.ts
-- memberName): dashed and $-prefixed names verbatim; leading underscores stripped;
-- names with a digit segment (`lan_1`) kept; otherwise camelCase, first letter lowered.
function cloudflare.ts_member_name(n)
  if string.find(n, "-", 1, true) or string.sub(n, 1, 1) == "$" then
    return n
  end
  local stripped = string.gsub(n, "^_+", "")
  if string.find(stripped, "_%d") then
    return stripped
  end
  local camel = string.gsub(stripped, "[_%-]+(%w)", string.upper)
  local lowered = string.lower(string.sub(camel, 1, 1)) .. string.sub(camel, 2)
  if RESERVED[lowered] then
    return camel
  end
  return lowered
end

--- cloudflare.camel_to_snake(key) -> protocol.ts camelToSnake (unknown input keys)
function cloudflare.camel_to_snake(key)
  return string.lower((string.gsub(key, "([a-z0-9])([A-Z])", "%1_%2")))
end

---------------------------------------------------------------------------------------
-- model edits (the model's key order lives in m.order: new objects must be registered)
---------------------------------------------------------------------------------------

local function new_object(m, t, keys)
  m.order[t] = keys or {}
  return t
end

local function set_trait(m, holder, key, value)
  if holder.traits == nil then
    holder.traits = new_object(m, {})
  end
  local traits = holder.traits
  if traits[key] == nil then
    local keys = m.order[traits]
    if keys == nil then
      keys = {}
      for k in pairs(traits) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      m.order[traits] = keys
    end
    keys[#keys + 1] = key
  end
  traits[key] = value
end

local function remove_trait(m, holder, key)
  holder.traits[key] = nil
  local keys = m.order[holder.traits]
  if keys then
    for i = #keys, 1, -1 do
      if keys[i] == key then
        table.remove(keys, i)
      end
    end
  end
end

local function ts_names(m, id)
  local names = {}
  for _, mem in ipairs(m:members(m.shapes[id])) do
    names[cloudflare.ts_member_name(mem.name)] = true
  end
  return names
end

--- cloudflare.invalid_pagination(m, op, trait) -> reason | nil (validatePaginated)
function cloudflare.invalid_pagination(m, op, pg)
  local root = string.match(tostring(pg.items or "result"), "^[^%.]*")
  local mode = pg.mode or "token"
  if mode ~= "single" then
    local token = type(pg.inputToken) == "string" and string.match(pg.inputToken, "^[^%.]*")
    if not token or not ts_names(m, op.input)[token] then
      return "pagination inputToken " .. tostring(pg.inputToken) .. " is not an input member"
    end
  end
  if root ~= "resultInfo" and not ts_names(m, op.output)[root] then
    return "pagination items " .. tostring(pg.items or "result") .. " is not an output member"
  end
  return nil
end

local function add_member(m, def, name, target, traits)
  if def.members == nil then
    def.members = new_object(m, {})
    if m.order[def] then
      local keys = m.order[def]
      keys[#keys + 1] = "members"
    end
  end
  local t = new_object(m, {}, {})
  for _, kv in ipairs(traits) do
    set_trait(m, { traits = t }, kv[1], kv[2])
  end
  def.members[name] = new_object(m, { target = target, traits = t }, { "target", "traits" })
  local keys = m.order[def.members]
  keys[#keys + 1] = name
end

local function add_shape(m, id, def)
  m.shapes[id] = def
  m.ids[#m.ids + 1] = id
end

-- The envelope's result_info (pagination.ts ResultInfo): every field optional and
-- nullable, wire names as Cloudflare sends them.
local RESULT_INFO_FIELDS = {
  { "count", "smithy.api#Double" },
  { "page", "smithy.api#Double" },
  { "per_page", "smithy.api#Double" },
  { "total_count", "smithy.api#Double" },
  { "total_pages", "smithy.api#Double" },
  { "cursor", "smithy.api#String" },
  { "cursors", "#ResultInfoCursors" },
  { "next_page_token", "smithy.api#String" },
  { "page_token", "smithy.api#String" },
}

local function add_result_info_shapes(m, problems)
  local ns = m.namespace
  local info_id, cursors_id = ns .. "#ResultInfo", ns .. "#ResultInfoCursors"
  for _, id in ipairs({ info_id, cursors_id }) do
    if m.shapes[id] ~= nil then
      problems[#problems + 1] = id
        .. ": the model already has this shape; the envelope's result_info needs its name"
      return nil
    end
  end
  local cursors = new_object(m, { type = "structure" }, { "type" })
  for _, f in ipairs({ "after", "before" }) do
    add_member(m, cursors, f, "smithy.api#String", { { NULLABLE, {} } })
  end
  local info = new_object(m, { type = "structure" }, { "type" })
  for _, f in ipairs(RESULT_INFO_FIELDS) do
    local target = f[2] == "#ResultInfoCursors" and cursors_id or f[2]
    add_member(m, info, f[1], target, { { NULLABLE, {} } })
  end
  info.traits = new_object(m, {
    [DOC] = "The v4 envelope's `result_info` block (pagination and totals; the fields vary"
      .. " per endpoint).",
  }, { DOC })
  m.order[info][#m.order[info] + 1] = "traits"
  add_shape(m, cursors_id, cursors)
  add_shape(m, info_id, info)
  return info_id
end

-- A dotted path of TS member names -> Smithy member names, walking from shape id.
local function smithy_path(m, id, path)
  local out = {}
  for segment in string.gmatch(path, "[^%.]+") do
    local def = id and m.shapes[id]
    if def and (def.type == "list" or def.type == "set") then
      id = def.member.target
      def = m.shapes[id]
    end
    local found
    for _, mem in ipairs(def and m:members(def) or {}) do
      if mem.name == segment then
        found = mem
        break
      end
    end
    if not found then
      for _, mem in ipairs(def and m:members(def) or {}) do
        if cloudflare.ts_member_name(mem.name) == segment then
          found = mem
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
  return compat.concat(out, ".")
end

local function each_member(m, fn)
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    if def.type == "structure" or def.type == "union" then
      for _, name in ipairs(m:keys(def.members or {})) do
        fn(def.members[name], id, def, name)
      end
    elseif (def.type == "list" or def.type == "set") and def.member then
      fn(def.member, id, def, "member")
    elseif def.type == "map" and def.value then
      fn(def.value, id, def, "value")
    end
  end
end

-- the model's service key dictionary: string entries only (protocol.ts reads a string)
local function key_dictionary(m)
  local meta = m.doc.metadata
  local dict = meta and meta.keyDictionary
  local out = {}
  if type(dict) == "table" then
    for k, v in pairs(dict) do
      if type(k) == "string" and type(v) == "string" then
        out[k] = v
      end
    end
  end
  return out
end

---------------------------------------------------------------------------------------
-- prepare
---------------------------------------------------------------------------------------

--- cloudflare.prepare(ctx) -> true | nil, message
-- Rewrites ctx.model (once per model) and installs ctx.cloudflare and the hooks.
function cloudflare.prepare(ctx)
  local m = ctx.model
  local problems = {}
  if not m.cloudflare then
    local state = { host_labels = {}, op_extra = {} }
    -- 1. member traits
    each_member(m, function(mem)
      local tr = mem.traits
      if tr == nil then
        return
      end
      if tr[T.nullable] ~= nil then
        set_trait(m, mem, NULLABLE, {})
      end
      if tr[T.envelope] ~= nil then
        set_trait(m, mem, PAYLOAD, {})
      end
      if tr[T.binary] ~= nil then
        set_trait(m, mem, PAYLOAD, {})
        mem.target = "smithy.api#Blob"
      end
      if tr[T.deep_query] ~= nil then
        local wire = tr[T.deep_query]
        set_trait(m, mem, QUERY, type(wire) == "string" and wire or "")
      end
    end)
    for _, id in ipairs(m.ids) do
      local def = m.shapes[id]
      if def.traits and def.traits[T.error_matchers] ~= nil then
        set_trait(m, def, MATCHERS, def.traits[T.error_matchers])
      end
    end

    -- 2. pagination traits Distilled cannot use make plain operations (generator.ts
    -- step 3, validatePaginated over the TS names, resultInfo counting as an output),
    -- then the paginated outputs get result_info and the others a bare payload root
    local paginated = {}
    for _, op in ipairs(m.operations) do
      local pg = op.def.traits and op.def.traits[PAGINATED]
      if type(pg) == "table" then
        local why = cloudflare.invalid_pagination(m, op, pg)
        if why then
          remove_trait(m, op.def, PAGINATED)
          m.warnings[#m.warnings + 1] = op.id
            .. ": "
            .. why
            .. "; emitted as a plain operation without _pages/_items, as Distilled does"
        else
          paginated[op.output] = true
        end
      end
    end
    local info_id
    local done = {}
    for _, op in ipairs(m.operations) do
      local out_id = op.output
      local def = m.shapes[out_id]
      if def and def.type == "structure" and not done[out_id] then
        done[out_id] = true
        local members = m:members(def)
        if paginated[out_id] then
          info_id = info_id or add_result_info_shapes(m, problems)
          if def.members and def.members[cloudflare.RESULT_INFO] ~= nil then
            problems[#problems + 1] = out_id
              .. ": a paginated output already has a member "
              .. cloudflare.RESULT_INFO
              .. " (the envelope's result_info goes there)"
          elseif info_id then
            add_member(m, def, cloudflare.RESULT_INFO, info_id, {
              { DOC, "Pagination info from the envelope's `result_info`." },
              { NULLABLE, {} },
            })
          end
        elseif #members == 1 and members[1].traits[T.envelope] ~= nil then
          set_trait(m, def.members[members[1].name], RAW, {})
        end
      end
    end

    -- 3. operations: pagination paths in Smithy names, host and jurisdiction
    local dict = key_dictionary(m)
    for _, op in ipairs(m.operations) do
      local tr = op.def.traits or {}
      local pg = tr[PAGINATED]
      if type(pg) == "table" then
        -- core reads an absent page size as none; ops.pagination would refuse it
        if type(pg.pageSize) == "string" then
          local root = string.match(pg.pageSize, "^[^%.]*")
          if not ts_names(m, op.input)[root] then
            remove_trait(m, { traits = pg }, "pageSize")
          end
        end
        for _, k in ipairs({ "inputToken", "pageSize" }) do
          if type(pg[k]) == "string" then
            pg[k] = smithy_path(m, op.input, pg[k])
          end
        end
        for _, k in ipairs({ "outputToken", "items", "hasNextPage" }) do
          if type(pg[k]) == "string" then
            pg[k] = smithy_path(m, op.output, pg[k])
          end
        end
      end
      local extra = {}
      local host = tr[T.host]
      if host ~= nil then
        if type(host) ~= "string" or not string.find(host, "^https://[^/]") then
          problems[#problems + 1] = op.id .. ": " .. T.host .. " must be an https origin"
        else
          extra.host = (string.gsub(host, "/+$", ""))
          local labels = {}
          for name in string.gmatch(host, "{([%w_]+)}") do
            labels[name] = true
          end
          state.host_labels[op.id] = labels
        end
      end
      if tr[T.jurisdiction] ~= nil then
        extra.jurisdiction = true
        state.jurisdiction = true
      end
      -- the key dictionary's wire name for a top-level output member, when it differs
      -- from the member's own (protocol.ts decodeResponse: "the docs sometimes document
      -- a field under a name the live wire doesn't use")
      local out_def = m.shapes[op.output]
      if out_def and out_def.type == "structure" then
        local fallback
        for _, mem in ipairs(m:members(out_def)) do
          local alt = dict[cloudflare.ts_member_name(mem.name)]
          local wire = mem.traits["smithy.api#jsonName"] or mem.name
          if alt ~= nil and alt ~= wire and mem.traits[PAYLOAD] == nil then
            fallback = fallback or {}
            fallback[mem.name] = alt
          end
        end
        extra.fallback_wire = fallback
      end
      if next(extra) then
        state.op_extra[op.id] = extra
      end
    end
    m.cloudflare = state
  end
  if #problems > 0 then
    table.sort(problems)
    return nil, compat.concat(problems, "\n")
  end

  local state = m.cloudflare
  ctx.cloudflare = state
  ctx.host_labels = state.host_labels
  -- the envelope profile: page mode stops on an empty page or result_info, so it needs
  -- only inputToken (generate.ts paginationProfiles.envelope.requires)
  ctx.strategy_fields = { page = { "inputToken" } }
  ctx.pagination_strategy = "cloudflare"
  ctx.member_hook = cloudflare.member_hook
  return true
end

--- cloudflare.member_hook(info, v): member fields the generic emitter does not know
function cloudflare.member_hook(info, v)
  if info.traits[T.deep_query] ~= nil then
    v.style = "deep"
  end
  if info.traits[T.form_file] ~= nil then
    v.form_file = true
  end
end

--- cloudflare.after_select(ctx, plan_ops)
-- optionalsNullable: shapes reachable from the selected operations' outputs and errors
-- (generator.ts responseReachable); and each op's extra descriptor fields.
function cloudflare.after_select(ctx, plan_ops)
  local roots = {}
  for _, op in ipairs(plan_ops) do
    roots[#roots + 1] = op.output
    for _, e in ipairs(op.errors) do
      roots[#roots + 1] = e
    end
    op.extra = ctx.cloudflare.op_extra[op.id]
  end
  ctx.nullable_owners = ctx.model:reachable(roots)
end

---------------------------------------------------------------------------------------
-- the client module (init.lua) and README construct section
---------------------------------------------------------------------------------------

local function jurisdiction_used(plan)
  for _, op in ipairs(plan.ops) do
    if op.extra and op.extra.jurisdiction then
      return true
    end
  end
  return false
end

--- cloudflare.options(plan) -> the client options (emit value)
function cloudflare.options(plan)
  local spec = plan.provider
  local options = {
    api_token = { secret = true },
    api_key = { secret = true },
    email = {},
    [spec.base_url.option] = {
      default = spec.base_url.default or cloudflare.DEFAULT_BASE_URL,
      env = spec.base_url.env,
    },
  }
  if jurisdiction_used(plan) then
    options.jurisdiction = {}
  end
  return options
end

--- cloudflare.client(plan) -> source of init.lua
function cloudflare.client(plan)
  local writer = require("distilled.gen.writer")
  local spec = plan.provider
  local b = emit.buffer()
  b:lines_of(
    writer.header(plan, spec.title .. ' client: what require("' .. spec.name .. '") returns.')
  )
  b:line("--")
  b:lines_of(emit.comment("local " .. spec.title .. ' = require("' .. spec.name .. '")'))
  b:lines_of(emit.comment("local client = " .. spec.title .. ".new({ host = ... })"))
  b:lines_of(
    emit.comment(
      "Auth: api_token (Authorization: Bearer), or api_key + email (X-Auth-Key, X-Auth-Email);"
        .. " without either, CLOUDFLARE_API_TOKEN or CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL."
        .. " See README.md next to this file."
    )
  )
  b:line('local Client = require("distilled.client")')
  b:line('local cloudflare = require("distilled.protocol.cloudflare")')
  b:blank()
  b:lines_of(
    emit.comment(
      "The module's own name, so the client loads under whatever directory it was vendored as."
    )
  )
  b:line("local MODULE = ... or " .. emit.string(spec.name))
  b:line('local service = require(MODULE .. ".service")')
  b:blank()
  b:line("return Client.define({")
  b:line("  service = service,")
  b:lines_of(emit.value(
    emit.call("cloudflare.new", {
      unknown_tag = spec.unknown_tag,
      parse_tag = spec.parse_tag,
      base_url_option = spec.base_url.option,
    }),
    "  ",
    "protocol = ",
    ","
  ))
  b:lines_of(emit.value(cloudflare.options(plan), "  ", "options = ", ","))
  b:line("})")
  return b:text()
end

--- cloudflare.readme_options(plan, add): the option rows of the README's Construct table
function cloudflare.readme_options(plan, add)
  add(
    "| `api_token` | API token (or OAuth access token), sent as `Authorization: Bearer`;"
      .. " a string, a secret, or `fn(host) -> value, err`. Default: `CLOUDFLARE_API_TOKEN` |"
  )
  add(
    "| `api_key`, `email` | global API key and account email (`X-Auth-Key`, `X-Auth-Email`),"
      .. " used without a token. Default: `CLOUDFLARE_API_KEY`, `CLOUDFLARE_EMAIL` |"
  )
  if jurisdiction_used(plan) then
    add(
      "| `jurisdiction` | R2 jurisdiction (`eu`, `fedramp`, ...) sent as `cf-r2-jurisdiction` on"
        .. " the operations that take one, unless the call sets `jurisdiction` |"
    )
  end
end

cloudflare._naming = naming
return cloudflare
