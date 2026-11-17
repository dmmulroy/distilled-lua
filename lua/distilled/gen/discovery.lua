-- Google discovery models (gcp, google-workspace): the model passes Distilled's
-- packages/gcp/scripts/generate.ts runs before its generator, as a pre-pass over a loaded
-- model. A provider spec opts in with
--
--   discovery = { error_matchers = "com.gcp.protocols#errorMatchers" },
--
-- and gen.plan calls discovery.prepare(m, spec.discovery) once per model. What it does:
--
-- 1. Base URL. Each Google service has its own host: `metadata.baseUrl` (rootUrl +
--    servicePath, ends with "/"). Distilled bakes it into every operation's T.Http trait
--    (generate.ts structPipes); here it is the model's `base_url` (m.discovery.base_url,
--    without the trailing "/"), which the writer passes to the hand-written protocol.
-- 2. URIs. A discovery path is relative (`v1/{+name}`) and uses RFC 6570 reserved
--    expansion `{+name}` for multi-segment resource names. It becomes the Smithy form
--    `/v1/{name+}` (a greedy label); distilled.gcp.protocol encodes a greedy label with
--    reserved expansion, as GcpProtocol does `{+name}`. base_url .. uri is the same URL.
-- 3. Request bodies (dev/src/codegen/flatten-payload.ts flattenStructurePayloads): a
--    `body` payload member whose target is a structure with members (and no
--    additionalProperties) is replaced by that structure's members, so the body's fields
--    are top-level input members: `insert_firewalls{ project, name, sourceRanges }`.
--    On a name clash the label or query member wins and the body field is left out
--    (the OpenAPI converter's rule). Other payloads stay a `body` member.
-- 4. Error matchers: the provider's matcher trait (`com.gcp.protocols#errorMatchers`,
--    `com.googleworkspace.protocols#errorMatchers`) is read as
--    `com.distilled.openapi#errorMatchers` (generate.ts errorMatchersTrait).
-- 5. Error fields: generate.ts declares code, message, status and details on every error
--    class (errors.defaultFields). code and message are instance fields already and
--    `status` is the HTTP status in Lua (the envelope's gRPC status is `rpc_status`, set by
--    the protocol); `details` is added as a Document member, filled from `error.details`.
-- 6. Operation names: a trailing `_` (an operation shape renamed because a schema owns
--    its name, convert.ts allocOp) is dropped (generate.ts opExportName).
local discovery = {}

local T_HTTP = "smithy.api#http"
local T_PAYLOAD = "smithy.api#httpPayload"
local T_MATCHERS = "com.distilled.openapi#errorMatchers"
local T_ADDITIONAL = "com.distilled.openapi#additionalProperties"
local T_ERROR = "smithy.api#error"

--- discovery.SPEC_KEYS: the keys of the provider spec's `discovery` table.
discovery.SPEC_KEYS = { error_matchers = true }

--- discovery.check_spec(value, problems): validates a provider spec's `discovery` table.
function discovery.check_spec(value, problems)
  if type(value) ~= "table" then
    problems[#problems + 1] = "provider spec: discovery must be { error_matchers = <trait id> }"
    return
  end
  for k in pairs(value) do
    if not discovery.SPEC_KEYS[k] then
      problems[#problems + 1] = "provider spec discovery: unknown key "
        .. tostring(k)
        .. " (allowed: error_matchers)"
    end
  end
  local tm = value.error_matchers
  if tm ~= nil and (type(tm) ~= "string" or not string.find(tm, "^[%w_.]+#[%w_]+$")) then
    problems[#problems + 1] = "provider spec discovery.error_matchers must be a trait id"
  end
end

--- discovery.op_name(name) -> the operation name without trailing underscores
function discovery.op_name(name)
  return (string.gsub(name, "_+$", ""))
end

--- discovery.uri(uri) -> the Smithy form of a discovery path ("v1/{+name}" -> "/v1/{name+}")
function discovery.uri(uri)
  local out = string.gsub(uri, "{%+([^}]*)}", "{%1+}")
  if string.sub(out, 1, 1) ~= "/" then
    out = "/" .. out
  end
  return out
end

-- set a key in a decoded object, keeping the model's key order list current
local function set_key(m, t, key, value)
  if t[key] == nil then
    local keys = m.order[t]
    if keys then
      keys[#keys + 1] = key
    end
  end
  t[key] = value
end

local function remove_key(m, t, key)
  t[key] = nil
  local keys = m.order[t]
  if keys then
    for i = #keys, 1, -1 do
      if keys[i] == key then
        table.remove(keys, i)
      end
    end
  end
end

local function new_object(m, t, keys)
  m.order[t] = keys or {}
  return t
end

-- 3. flattenStructurePayloads, for one operation input
local function flatten(m, input_id, stats)
  local input = m.shapes[input_id]
  if type(input) ~= "table" or input.type ~= "structure" or type(input.members) ~= "table" then
    return
  end
  local payload_name
  for _, name in ipairs(m:keys(input.members)) do
    local mem = input.members[name]
    if mem.traits and mem.traits[T_PAYLOAD] ~= nil then
      payload_name = name
      break
    end
  end
  if payload_name == nil then
    return
  end
  local body = m.shapes[input.members[payload_name].target]
  if
    type(body) ~= "table"
    or body.type ~= "structure"
    or next(body.members or {}) == nil
    or (body.traits and body.traits[T_ADDITIONAL] ~= nil)
  then
    return
  end
  -- the body's fields first, then the path and query members: Distilled emits the input
  -- as S.Extend(<body>, S.Struct({ labels, queries })), whose props come in that order
  local members, order = {}, {}
  for _, name in ipairs(m:keys(input.members)) do
    if name ~= payload_name then
      members[name] = input.members[name]
    end
  end
  for _, name in ipairs(m:keys(body.members)) do
    if members[name] ~= nil then
      stats.shadowed = stats.shadowed + 1
    else
      local src = body.members[name]
      local traits = new_object(m, {})
      for _, tk in ipairs(m:keys(src.traits or {})) do
        set_key(m, traits, tk, src.traits[tk])
      end
      members[name] = new_object(
        m,
        { target = src.target, traits = traits },
        { "target", "traits" }
      )
      order[#order + 1] = name
    end
  end
  for _, name in ipairs(m:keys(input.members)) do
    if name ~= payload_name then
      order[#order + 1] = name
    end
  end
  input.members = new_object(m, members, order)
  stats.flattened = stats.flattened + 1
end

--- discovery.prepare(m, opts) -> true | nil, message
-- Runs the passes above on a loaded model, once (m.discovery is set afterwards).
function discovery.prepare(m, opts)
  if m.discovery then
    return true
  end
  opts = opts or {}
  local meta = type(m.doc.metadata) == "table" and m.doc.metadata or {}
  local base = meta.baseUrl
  if type(base) ~= "string" or not string.find(base, "^https?://[^/]") then
    return nil,
      (m.path or "model") .. ": a discovery model needs metadata.baseUrl (rootUrl + servicePath)"
  end
  local problems = {}
  local stats = { flattened = 0, shadowed = 0 }
  local inputs_seen = {}
  for _, op in ipairs(m.operations) do
    local http = op.def.traits and op.def.traits[T_HTTP]
    if type(http) == "table" and type(http.uri) == "string" then
      if string.find(http.uri, "^/") then
        problems[#problems + 1] = op.id .. ": a discovery path is relative, got " .. http.uri
      else
        http.uri = discovery.uri(http.uri)
      end
    end
    if not inputs_seen[op.input] then
      inputs_seen[op.input] = true
      flatten(m, op.input, stats)
    end
  end
  local matcher_trait = opts.error_matchers
  for _, id in ipairs(m.ids) do
    local def = m.shapes[id]
    local traits = def.traits
    if type(traits) == "table" and matcher_trait and traits[matcher_trait] ~= nil then
      set_key(m, traits, T_MATCHERS, traits[matcher_trait])
      remove_key(m, traits, matcher_trait)
    end
    if type(traits) == "table" and traits[T_ERROR] ~= nil and def.type == "structure" then
      def.members = def.members or new_object(m, {})
      if def.members.details == nil then
        set_key(
          m,
          def.members,
          "details",
          new_object(m, {
            target = "smithy.api#Document",
            traits = new_object(m, {
              ["smithy.api#documentation"] = "The error envelope's `error.details` (google.rpc"
                .. " detail messages, each with an `@type`).",
            }, { "smithy.api#documentation" }),
          }, { "target", "traits" })
        )
      end
    end
  end
  -- the matcher trait is known now: drop the load-time "ignored unknown trait" warnings
  if matcher_trait then
    local kept = {}
    for _, w in ipairs(m.warnings) do
      if not string.find(w, "ignored unknown trait " .. matcher_trait, 1, true) then
        kept[#kept + 1] = w
      end
    end
    m.warnings = kept
  end
  if #problems > 0 then
    table.sort(problems)
    return nil, table.concat(problems, "\n", 1, math.min(#problems, 20))
  end
  m.discovery = {
    base_url = (string.gsub(base, "/+$", "")),
    flattened = stats.flattened,
    shadowed = stats.shadowed,
  }
  return true
end

--- discovery.spec_for_model(spec, m) -> a copy of the validated spec for one prepared model
-- Its base URL is the model's own (metadata.baseUrl); the generic base URL option is not a
-- client option (Distilled has none: the `endpoint` option replaces the origin instead).
function discovery.spec_for_model(spec, m)
  local out = {}
  for k, v in pairs(spec) do
    out[k] = v
  end
  out.base_url = { default = m.discovery.base_url, option = spec.base_url.option }
  if spec.client_options then
    out.client_options = {}
    for k, v in pairs(spec.client_options) do
      if k ~= spec.base_url.option then
        out.client_options[k] = v
      end
    end
  end
  if spec.option_docs then
    out.option_docs = {}
    for _, d in ipairs(spec.option_docs) do
      if not d.base_url then
        out.option_docs[#out.option_docs + 1] = d
      end
    end
  end
  return out
end

return discovery
