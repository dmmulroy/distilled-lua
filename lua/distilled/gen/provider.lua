-- Provider specs: the small hand-written part per provider (plan, "Using distilled-lua as
-- a tool"). Distilled's equivalent is the `SdkSpec` in each package's scripts/generate.ts
-- plus its hand-written protocol.ts, credentials.ts and errors.ts; here it is one
-- declarative Lua table, validated strictly (unknown keys are errors).
--
--   return {
--     name = "neon",                          -- module name (require("neon")), type prefix
--     title = "Neon",                         -- optional; human name in docs and spans
--     base_url = {                            -- or just the URL string
--       default = "https://console.neon.tech/api/v2",
--       option = "base_url",                  -- client option that overrides it
--       env = "NEON_API_BASE_URL",            -- environment variable that overrides it
--     },
--     auth = { kind = "bearer", from = "api_key", env = "NEON_API_KEY" },
--          -- kind "bearer": authorization: Bearer <secret>
--          -- kind "header": <header>: <secret>   (header = "x-api-key")
--          -- kind "none"
--     unknown_tag = "UnknownNeonError",       -- tag of the error nothing else matched
--     parse_tag = "NeonParseError",           -- tag of an unparseable success body
--     error_envelope = { code = "/code", message = { "/message", "/error" } },  -- pointer(s)
--     error_fields_at = "/error",             -- where error class fields live, optional
--     status_map = { [418] = "Teapot" },      -- status -> tag entries over errors.STATUS_MAP;
--                                             -- a tag is a built-in error or a model error
--     classify_error = "neon_extra.classify", -- module returning fn(info) -> err | nil
--     protocol = "neon_extra.protocol",       -- escape hatch: module returning
--                                             -- fn(service, spec) -> protocol
--     naming = {
--       members = "wire",                     -- "wire" (keep wire names) | "snake_case"
--       words = { "OAuth" },                  -- extra mixed-case words for snake_case
--       operations = { GetThing = "fetch_thing" },   -- per-operation method names
--     },
--     pagination = { items_fallback = "items" },     -- items path when the trait has none;
--                                                    -- modes = { page = "total_count" }
--     allow_unsupported = { "streaming" },   -- emit operations the runtime refuses at
--                                            -- call time (SdkError) instead of failing
--                                            -- (provider.UNSUPPORTED)
--     models = {                             -- packages with several models (one module
--                                            -- each, `require("hetzner.servers")`)
--       skip = { "pricing" },                -- models not generated (Lua model names)
--       override = {                         -- per-model changes, keyed by Lua model name
--         servers = {
--           title = "HetznerServers",        -- class name (default: title .. PascalCase)
--           base_url = "https://other.test", -- a URL (replaces the default only) or a
--         },                                 -- partial { default, option, env }
--         platform = {                       -- a model with its own auth (task 27):
--           auth = { kind = "bearer", from = "api_key", env = "OTHER_KEY" },
--           options = false,                 -- false: the model has none of the package's
--           headers = { ["X-V"] = "2" },     -- replaces the package's headers
--         },
--       },                                   -- (provider.MODEL_SPEC_KEYS lists the keys)
--     },
--   }
--
-- More keys (options, headers, templated base URLs, basic auth, OAuth, error classes,
-- transforms, hand-written glue): see gen/provider_ext.lua and docs/generating.md.
local compat = require("distilled.compat")
local naming = require("distilled.gen.naming")
-- keys beyond the classic ones (options, headers, templates, envelopes, glue, ...): task 13
local ext = require("distilled.gen.provider_ext")

local provider = {}

local function is_tag(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function is_module(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*[%.A-Za-z0-9_]*$") ~= nil
end

local function is_pointer(s)
  return type(s) == "string" and (s == "" or string.sub(s, 1, 1) == "/")
end

local function is_env(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function check_keys(where, t, allowed, problems)
  local list = {}
  for k in pairs(t) do
    list[#list + 1] = k
  end
  table.sort(list, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(list) do
    if not allowed[k] then
      local names = {}
      for name in pairs(allowed) do
        names[#names + 1] = name
      end
      table.sort(names)
      problems[#problems + 1] = where
        .. ": unknown key "
        .. tostring(k)
        .. " (allowed: "
        .. compat.concat(names, ", ")
        .. ")"
    end
  end
end

-- A base URL: a URL string or { default, option, env }. Returns the table form (empty
-- when unusable) and adds problems under `where`. `partial` (per-model overrides) allows
-- a table without `default`.
local function normalize_base_url(where, base, p, partial)
  if type(base) == "string" then
    base = { default = base }
  end
  if type(base) ~= "table" then
    p[#p + 1] = where .. " must be a URL string or { default, option, env }"
    return {}
  end
  check_keys(where, base, { default = true, option = true, env = true }, p)
  if partial and base.default == nil then
    -- keeps the package's default
  elseif type(base.default) ~= "string" or not string.find(base.default, "^https?://[^/]") then
    p[#p + 1] = where .. ".default must be an http(s) URL"
  elseif string.sub(base.default, -1) == "/" then
    p[#p + 1] = where .. ".default must not end with /"
  end
  if base.option ~= nil and not naming.is_identifier(base.option) then
    p[#p + 1] = where .. ".option must be an identifier"
  end
  if base.env ~= nil and not is_env(base.env) then
    p[#p + 1] = where .. ".env must be an environment variable name"
  end
  return base
end

local TOP = {
  name = true,
  title = true,
  base_url = true,
  auth = true,
  unknown_tag = true,
  parse_tag = true,
  error_envelope = true,
  error_fields_at = true,
  status_map = true,
  classify_error = true,
  protocol = true,
  naming = true,
  pagination = true,
  allow_unsupported = true,
  models = true,
  -- Google discovery models (gcp, google-workspace): gen/discovery.lua (task 21)
  discovery = true,
  rpc = true, -- RPC models without http traits (gen/rpc.lua, task 22)
  proto = true, -- proto-sourced providers: gRPC, gRPC-Web, Connect (gen/proto.lua, task 23)
}
for k in pairs(ext.TOP) do
  TOP[k] = true
end

-- Runtime gaps a provider may acknowledge (see allow_unsupported above). Multipart bodies
-- were the first; request.build encodes them since task 08 (CLOSED_GAPS below).
provider.UNSUPPORTED = {
  -- Operations with a streaming trait (gen/traits.lua traits.STREAMING: gRPC server or
  -- client streaming, com.distilled.openapi#streamWhen). Server/client streaming ones
  -- are emitted with op.unsupported = "streaming" and fail with SdkError at call time;
  -- a streamWhen one is emitted as its plain (non-streaming) call.
  streaming = "streaming operations (no streaming in the runtime yet)",
}

-- Spec keys a models.override entry may carry besides title and base_url (task 27): the
-- parts of a package's TS glue that differ per model (Distilled writes one
-- credentials/protocol pair per model: ClerkPlatformProtocol, ConvexDeploymentProtocol,
-- FunctionsProtocol, ...). Each replaces the package's key of that name for the model;
-- `false` removes it. The merged spec is validated whole, like a package spec.
provider.MODEL_SPEC_KEYS = {
  auth = true,
  options = true,
  headers = true,
  require_one_of = true,
  public_operations = true,
  oauth = true,
  user_agent = true,
  error_envelope = true,
  unknown_fields = true,
  transform_response = true,
  empty_json_body = true,
  glue = true,
}

-- the keys of a base_url table that only the extended form (provider_ext) knows
local BASE_EXT_KEYS = { trim_slash = true, ensure_suffix = true, origin = true }

-- Does this override need the whole spec re-validated (task 27), or is it the classic
-- title/base_url change (task 10)? Classic overrides keep generating exactly as before.
local function full_override(o)
  for k in pairs(provider.MODEL_SPEC_KEYS) do
    if o[k] ~= nil then
      return true
    end
  end
  local b = o.base_url
  if type(b) == "table" then
    for k, v in pairs(b) do
      if v == false or BASE_EXT_KEYS[k] or type(v) == "table" then
        return true
      end
    end
    if
      type(b.env) == "table"
      or (b.default ~= nil and string.find(tostring(b.default), "{", 1, true))
    then
      return true
    end
  elseif type(b) == "string" and string.find(b, "{", 1, true) then
    return true
  end
  return false
end

-- The raw spec of one model: the package's raw spec with the override's keys replacing
-- the package's (false removes one). base_url merges field by field over the package's
-- (a string is the default), so an override names only what differs.
local function merged_raw(raw, o)
  local m = {}
  for k, v in pairs(raw) do
    m[k] = v
  end
  m.models = nil
  for k in pairs(provider.MODEL_SPEC_KEYS) do
    if o[k] == false then
      m[k] = nil
    elseif o[k] ~= nil then
      m[k] = o[k]
    end
  end
  if o.base_url ~= nil then
    local base = {}
    if type(raw.base_url) == "table" then
      for k, v in pairs(raw.base_url) do
        base[k] = v
      end
    elseif raw.base_url ~= nil then
      base.default = raw.base_url
    end
    local ob = type(o.base_url) == "table" and o.base_url or { default = o.base_url }
    for k, v in pairs(ob) do
      if v == false then
        base[k] = nil
      else
        base[k] = v
      end
    end
    m.base_url = base
  end
  return m
end

-- Gaps that were closed: listing one is a stale provider spec, reported as such.
provider.CLOSED_GAPS = {
  multipart = "request.build encodes multipart bodies now; remove it from allow_unsupported",
}

--- provider.is_model_name(s) -> boolean: a model's Lua name (the last part of its module
-- name, `hetzner.server_actions`): lower-case letters, digits and `_`, starting with a
-- letter. Keywords are allowed: the package index reaches them as index["end"].
function provider.is_model_name(s)
  return type(s) == "string" and string.find(s, "^[a-z][a-z0-9_]*$") ~= nil
end

--- provider.check_models(spec, names) -> true | nil, message
-- Every model that `models.skip` and `models.override` name must exist in the package
-- (names: the Lua names of the package's models). Fails early on a stale spec.
function provider.check_models(spec, names)
  local known = {}
  for _, n in ipairs(names) do
    known[n] = true
  end
  local p = {}
  for _, what in ipairs({ "skip", "override" }) do
    local list = {}
    for n in pairs(spec.models[what]) do
      list[#list + 1] = n
    end
    table.sort(list)
    for _, n in ipairs(list) do
      if not known[n] then
        local cands = {}
        for _, k in ipairs(names) do
          cands[#cands + 1] = k
        end
        table.sort(cands)
        p[#p + 1] = "provider spec models."
          .. what
          .. " names "
          .. n
          .. ", which is not a model of the package; nearest: "
          .. compat.concat(naming.nearest(n, cands, 3), ", ")
      end
    end
  end
  if #p > 0 then
    return nil, compat.concat(p, "\n")
  end
  return true
end

--- provider.for_model(spec, model_name) -> the spec for one model of a multi-model package
-- A validated copy whose `name` is the module name (`hetzner.servers`: it sets the module
-- name, the type prefix and the README), whose `title` is the class name (default: the
-- package title and the model in PascalCase, `HetznerServers`), with the model's
-- `models.override` applied. `package` keeps the package's own name.
function provider.for_model(spec, model_name)
  if type(spec) ~= "table" or not spec.__validated then
    error("distilled.gen.provider.for_model: expected a validated spec", 2)
  end
  if not provider.is_model_name(model_name) then
    error("distilled.gen.provider.for_model: bad model name " .. tostring(model_name), 2)
  end
  local ov = spec.models.override[model_name] or {}
  local out = {}
  -- a task-27 override: the model's own validated spec (auth, options, headers, ...)
  for k, v in pairs(ov.spec or spec) do
    out[k] = v
  end
  out.models = spec.models
  local pascal = string.gsub(model_name, "_?(%w)(%w*)", function(first, rest)
    return string.upper(first) .. rest
  end)
  out.package = spec.name
  out.model_name = model_name
  out.name = spec.name .. "." .. model_name
  out.title = ov.title or (string.gsub(spec.title, "[^%w_]", "") .. pascal)
  if ov.spec then
    return out
  end
  out.base_url = ov.base_url or spec.base_url
  if out.runtime and ov.base_url then
    ext.override_base_url(out)
  end
  return out
end

--- provider.validate(spec [, opts]) -> normalized spec | nil, message
-- Normalized: base_url is always a table, auth always has kind; defaults filled in.
-- opts.dir: the directory a relative `glue` path is read from (provider.load sets it).
function provider.validate(spec, opts)
  local p = {}
  if type(spec) ~= "table" then
    return nil, "provider spec: expected a table, got " .. type(spec)
  end
  check_keys("provider spec", spec, TOP, p)
  -- the classic checks below see the spec without the extended keys (ext.reduce); the
  -- originals are checked by ext.validate at the end
  local raw = spec
  spec = ext.reduce(raw)

  local out = {}
  if not naming.is_identifier(spec.name) or string.find(spec.name, "%u") then
    p[#p + 1] = "provider spec: name must be a lower-case Lua identifier (the module name)"
  end
  out.name = spec.name
  if spec.title ~= nil and type(spec.title) ~= "string" then
    p[#p + 1] = "provider spec: title must be a string"
  end
  out.title = spec.title
    or (
      type(spec.name) == "string"
      and (string.upper(string.sub(spec.name, 1, 1)) .. string.sub(spec.name, 2))
    )

  -- base_url (a discovery model has its own: gen/discovery.lua replaces this placeholder;
  -- an rpc model's protocol finds its hosts itself: no base URL needed)
  if spec.discovery ~= nil and spec.base_url == nil then
    spec.base_url = "https://discovery.googleapis.invalid"
  end
  local base = {}
  if spec.rpc == nil or spec.base_url ~= nil then
    base = normalize_base_url("provider spec base_url", spec.base_url, p)
  end
  out.base_url = { default = base.default, option = base.option or "base_url", env = base.env }

  -- auth
  local auth = spec.auth
  if auth == nil then
    auth = { kind = "none" }
  end
  if type(auth) ~= "table" then
    p[#p + 1] = "provider spec: auth must be a table"
    auth = { kind = "none" }
  end
  check_keys("provider spec auth", auth, { kind = true, from = true, env = true, header = true }, p)
  if auth.kind == "bearer" or auth.kind == "header" then
    if not naming.is_identifier(auth.from) then
      p[#p + 1] = "provider spec auth.from must name the client option holding the secret"
    end
    if auth.env ~= nil and not is_env(auth.env) then
      p[#p + 1] = "provider spec auth.env must be an environment variable name"
    end
    if auth.kind == "header" then
      if type(auth.header) ~= "string" or not string.find(auth.header, "^[A-Za-z0-9-]+$") then
        p[#p + 1] = "provider spec auth.header must be a header name"
      end
    elseif auth.header ~= nil then
      p[#p + 1] = "provider spec auth: header is for kind = header"
    end
  elseif auth.kind == "none" then
    if auth.from ~= nil or auth.env ~= nil or auth.header ~= nil then
      p[#p + 1] = "provider spec auth: kind none takes no other keys"
    end
  else
    p[#p + 1] = "provider spec auth.kind must be bearer, header, basic or none, got "
      .. tostring(auth.kind)
  end
  out.auth = {
    kind = auth.kind,
    from = auth.from,
    env = auth.env,
    header = auth.header and string.lower(auth.header),
  }
  if out.auth.from ~= nil and out.auth.from == out.base_url.option then
    p[#p + 1] = "provider spec: auth.from and base_url.option are the same option"
  end

  -- error tags
  for _, key in ipairs({ "unknown_tag", "parse_tag" }) do
    if not is_tag(spec[key]) then
      p[#p + 1] = "provider spec: " .. key .. " must be an error tag (a name like UnknownNeonError)"
    end
    out[key] = spec[key]
  end

  -- error_envelope: checked and normalized by ext.validate (pointer lists)
  if spec.error_fields_at ~= nil and not is_pointer(spec.error_fields_at) then
    p[#p + 1] = "provider spec: error_fields_at must be a JSON pointer"
  end
  out.error_fields_at = spec.error_fields_at

  if spec.status_map ~= nil then
    if type(spec.status_map) ~= "table" then
      p[#p + 1] = "provider spec: status_map must be { [status] = tag }"
    else
      out.status_map = {}
      for k, v in pairs(spec.status_map) do
        if type(k) ~= "number" or k < 400 or k > 599 or k ~= math.floor(k) then
          p[#p + 1] = "provider spec status_map: key " .. tostring(k) .. " is not a 4xx/5xx status"
        elseif not is_tag(v) then
          p[#p + 1] = "provider spec status_map[" .. k .. "] must be an error tag"
        else
          out.status_map[k] = v
        end
      end
    end
  end

  for _, key in ipairs({ "classify_error", "protocol" }) do
    if spec[key] ~= nil and not is_module(spec[key]) then
      p[#p + 1] = "provider spec: "
        .. key
        .. " must be a module name (a string); functions cannot be written into generated code"
    end
    out[key] = spec[key]
  end

  local nm = spec.naming or {}
  if type(nm) ~= "table" then
    p[#p + 1] = "provider spec: naming must be a table"
    nm = {}
  end
  check_keys("provider spec naming", nm, { members = true, words = true, operations = true }, p)
  if nm.members ~= nil and nm.members ~= "wire" and nm.members ~= "snake_case" then
    p[#p + 1] = "provider spec naming.members must be wire or snake_case"
  end
  if nm.words ~= nil then
    if type(nm.words) ~= "table" then
      p[#p + 1] = "provider spec naming.words must be a list of words"
    else
      for i, w in ipairs(nm.words) do
        if type(w) ~= "string" or not string.find(w, "^%u[%w]*$") then
          p[#p + 1] = "provider spec naming.words[" .. i .. "] must be a capitalised word"
        end
      end
    end
  end
  if nm.operations ~= nil then
    if type(nm.operations) ~= "table" then
      p[#p + 1] = "provider spec naming.operations must be { OpName = method_name }"
    else
      for k, v in pairs(nm.operations) do
        if type(k) ~= "string" or not naming.is_identifier(v) then
          p[#p + 1] = "provider spec naming.operations["
            .. tostring(k)
            .. "] must be a Lua identifier"
        end
      end
    end
  end
  out.naming = {
    members = nm.members or "wire",
    words = nm.words or {},
    operations = nm.operations or {},
  }

  local pg = spec.pagination or {}
  if type(pg) ~= "table" then
    p[#p + 1] = "provider spec: pagination must be a table"
    pg = {}
  end
  check_keys("provider spec pagination", pg, { items_fallback = true, modes = true }, p)
  if pg.items_fallback ~= nil and type(pg.items_fallback) ~= "string" then
    p[#p + 1] = "provider spec pagination.items_fallback must be a string"
  end
  out.pagination = { items_fallback = pg.items_fallback or "items" }
  -- pagination.modes = { page = "total_count" }: the runtime strategy for a trait mode
  -- (Distilled's paginationProfiles; task 27). Keys are smithy.api#paginated modes,
  -- values distilled.paginate modes.
  if pg.modes ~= nil then
    local runtime_modes = require("distilled.paginate").MODES
    if type(pg.modes) ~= "table" then
      p[#p + 1] = "provider spec pagination.modes must be { [trait mode] = runtime mode }"
    else
      out.pagination.modes = {}
      for k, v in pairs(pg.modes) do
        if type(k) ~= "string" or not runtime_modes[k] or k == "total_count" then
          p[#p + 1] = "provider spec pagination.modes: " .. tostring(k) .. " is not a trait mode"
        elseif type(v) ~= "string" or not runtime_modes[v] then
          p[#p + 1] = "provider spec pagination.modes."
            .. k
            .. ": "
            .. tostring(v)
            .. " is not a distilled.paginate mode"
        else
          out.pagination.modes[k] = v
        end
      end
    end
  end

  -- models: multi-model packages (one spec, one module per model)
  out.models = { skip = {}, override = {} }
  if spec.models ~= nil then
    local ms = spec.models
    if type(ms) ~= "table" then
      p[#p + 1] = "provider spec: models must be { skip = { ... }, override = { ... } }"
      ms = {}
    end
    check_keys("provider spec models", ms, { skip = true, override = true }, p)
    if ms.skip ~= nil then
      if type(ms.skip) ~= "table" then
        p[#p + 1] = "provider spec models.skip must be a list of model names"
      else
        for k in pairs(ms.skip) do
          if type(k) ~= "number" then
            p[#p + 1] = "provider spec models.skip must be a list of model names"
            break
          end
        end
        for i, v in ipairs(ms.skip) do
          if not provider.is_model_name(v) then
            p[#p + 1] = "provider spec models.skip["
              .. i
              .. "] must be a model name (lower-case, like server_actions)"
          elseif out.models.skip[v] then
            p[#p + 1] = "provider spec models.skip lists " .. v .. " twice"
          else
            out.models.skip[v] = true
          end
        end
      end
    end
    if ms.override ~= nil then
      if type(ms.override) ~= "table" then
        p[#p + 1] = "provider spec models.override must be { [model] = { base_url, title } }"
      else
        local names = {}
        for k in pairs(ms.override) do
          names[#names + 1] = k
        end
        table.sort(names, function(a, b)
          return tostring(a) < tostring(b)
        end)
        for _, k in ipairs(names) do
          local o = ms.override[k]
          local where = "provider spec models.override." .. tostring(k)
          if not provider.is_model_name(k) then
            p[#p + 1] = "provider spec models.override: key "
              .. tostring(k)
              .. " is not a model name (lower-case, like server_actions)"
          elseif out.models.skip[k] then
            p[#p + 1] = where .. ": the model is also in models.skip"
          elseif type(o) ~= "table" then
            p[#p + 1] = where .. " must be a table"
          else
            local allowed = { base_url = true, title = true }
            for key in pairs(provider.MODEL_SPEC_KEYS) do
              allowed[key] = true
            end
            check_keys(where, o, allowed, p)
            local ov = {}
            if o.title ~= nil then
              if type(o.title) ~= "string" or not naming.is_identifier(o.title) then
                p[#p + 1] = where .. ".title must be a Lua identifier (it names the class)"
              end
              ov.title = o.title
            end
            if full_override(o) then
              -- the model's own spec: the package's raw spec with the override applied,
              -- validated whole (its runtime data, options and docs are its own)
              local mspec, merr = provider.validate(merged_raw(raw, o), opts)
              if not mspec then
                for line in string.gmatch(merr, "[^\n]+") do
                  p[#p + 1] = where .. ": " .. line
                end
              else
                ov.spec = mspec
              end
            elseif o.base_url ~= nil then
              local b = normalize_base_url(where .. ".base_url", o.base_url, p, true)
              ov.base_url = {
                default = b.default or out.base_url.default,
                option = b.option or out.base_url.option,
                env = b.env or out.base_url.env,
              }
              if out.auth.from ~= nil and ov.base_url.option == out.auth.from then
                p[#p + 1] = where .. ": auth.from and base_url.option are the same option"
              end
            end
            out.models.override[k] = ov
          end
        end
      end
    end
  end

  if spec.rpc ~= nil then
    out.rpc = require("distilled.gen.rpc").validate(spec.rpc, p)
  end

  out.allow_unsupported = {}
  if spec.allow_unsupported ~= nil then
    if type(spec.allow_unsupported) ~= "table" then
      p[#p + 1] = "provider spec: allow_unsupported must be a list"
    else
      for i, v in ipairs(spec.allow_unsupported) do
        if provider.CLOSED_GAPS[v] and not provider.UNSUPPORTED[v] then
          p[#p + 1] = "provider spec allow_unsupported["
            .. i
            .. "]: "
            .. tostring(v)
            .. " is supported: "
            .. provider.CLOSED_GAPS[v]
        elseif not provider.UNSUPPORTED[v] then
          p[#p + 1] = "provider spec allow_unsupported[" .. i .. "]: unknown gap " .. tostring(v)
        else
          out.allow_unsupported[v] = true
        end
      end
    end
  end

  if spec.discovery ~= nil then
    require("distilled.gen.discovery").check_spec(spec.discovery, p)
    out.discovery = spec.discovery
  end

  ext.validate(raw, out, p, opts)

  -- proto-sourced providers (gRPC, gRPC-Web, Connect): validated by gen/proto.lua
  if spec.proto ~= nil then
    local r, rp = require("distilled.gen.proto").validate(spec.proto, out)
    for _, problem in ipairs(rp or {}) do
      p[#p + 1] = problem
    end
    out.proto = r
  end

  if #p > 0 then
    return nil, compat.concat(p, "\n")
  end
  out.__validated = true
  return out
end

--- provider.load(path) -> normalized spec | nil, message
function provider.load(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "cannot read provider spec: " .. tostring(err)
  end
  local text = f:read("*a")
  f:close()
  local chunk, cerr = compat.load(text, "@" .. path)
  if not chunk then
    return nil, "provider spec " .. path .. ": " .. tostring(cerr)
  end
  local ok, spec = compat.pcall(chunk)
  if not ok then
    return nil, "provider spec " .. path .. " raised: " .. tostring(spec)
  end
  local out, verr = provider.validate(spec, { dir = string.match(path, "^(.*)/[^/]*$") or "." })
  if not out then
    return nil, path .. ":\n" .. verr
  end
  return out
end

return provider
