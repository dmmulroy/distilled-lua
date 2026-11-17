-- Provider-spec keys beyond bearer/header auth and one base URL (task 13). The survey in
-- docs/providers-survey.md says which Distilled package needs which; each key mirrors a
-- pattern its hand-written credentials.ts / protocol.ts repeats:
--
--   options = { [name] = { secret, env = "A" | { "A", "B" }, default, required, type,
--                          choices = { "x", "y" } | { x = "text" }, ignore_case,
--                          invalid = "error" | "default", trim_slash, strip_scheme, doc } },
--   auth = { kind = "bearer" | "header" | "basic" | "none", from, env = "A" | { ... },
--            header, prefix = "Token ", optional = true, username, password },
--   headers = { ["Anthropic-Version"] = "{version}",           -- a template
--               authorization = { "Bearer {access_token}", "{token_id}:{token}" },
--               ["x-basic"] = { basic = "{user}:{password}" } },  -- Basic base64(...)
--   base_url = { default = "https://api.{site}" | nil (required), option, env = "A" | {...},
--                trim_slash, ensure_suffix = "/api", origin = true | { label, example } },
--   require_one_of = { "api_key", "access_token" },
--   public_operations = { "GetThing" },        -- no secret header, no required check
--   oauth = { token_url = "{base_url}/oauth/token", client_id, client_secret, into,
--             auth = "basic" | "form", scope, extra = { field = option }, default_ttl_s,
--             refresh_window_s, reuse = "window" | "half", required, label },
--   user_agent = { default = "distilled.cloud-github", env = "GITHUB_USER_AGENT" },
--   error_envelope = { code = "/a" | { "/a", "/b" }, message = ..., non_empty = true },
--   error_classes = { Gone = { categories = { "NotFoundError" }, retryable = false } },
--   unknown_fields = { reason = "/reason" },
--   transform_response = { "strip_nulls", { unwrap = "result", skip_paginated = true } },
--   glue = "glue/<name>.lua",   -- hand-written Lua copied next to the client (glue.lua)
--
-- A template's `{name}` is an option's value. provider.validate calls ext.reduce first
-- (the classic checks see only the keys they know) and ext.validate last.
local compat = require("distilled.compat")
local naming = require("distilled.gen.naming")

local ext = {}

ext.TOP = {
  options = true,
  headers = true,
  require_one_of = true,
  public_operations = true,
  oauth = true,
  user_agent = true,
  error_classes = true,
  unknown_fields = true,
  transform_response = true,
  glue = true,
}

local AUTH_EXT = { prefix = true, optional = true, username = true, password = true }
local BASE_EXT = { trim_slash = true, ensure_suffix = true, origin = true }
local OPTION_KEYS = {
  secret = true,
  env = true,
  default = true,
  required = true,
  type = true,
  choices = true,
  ignore_case = true,
  invalid = true,
  trim_slash = true,
  strip_scheme = true,
  doc = true,
}
local OAUTH_KEYS = {
  token_url = true,
  client_id = true,
  client_secret = true,
  into = true,
  auth = true,
  scope = true,
  extra = true,
  default_ttl_s = true,
  refresh_window_s = true,
  reuse = true,
  required = true,
  label = true,
}

--- The glue functions a provider may define, and what rest.new does with each.
ext.HOOKS = {
  settings = "fn(settings, host, route) -> settings | nil, err: derive values after options",
  base_url = "fn(settings, route) -> url | nil, err: the base URL (per operation)",
  headers = "fn(settings, route, headers) -> headers: change the headers",
  transform_input = "fn(input, op) -> input: before the request is built",
  error_envelope = "fn(body) -> { code, message }",
  classify_error = "fn(info) -> err | nil: consulted first for a failure",
  classify_success = "fn(info) -> err | nil: a failure reported in a 2xx body",
  transform_response = "fn(body, op) -> body",
  unknown_error = "fn(info) -> err: the error nothing else matched",
}

local CATEGORIES = {}
for _, name in ipairs(require("distilled.errors").CATEGORIES) do
  CATEGORIES[name] = true
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do
    list[#list + 1] = k
  end
  table.sort(list, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return list
end

local function is_env(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_pointer(s)
  return type(s) == "string" and (s == "" or string.sub(s, 1, 1) == "/")
end

local function is_tag(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z][A-Za-z0-9_]*$") ~= nil
end

local function is_list(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

local function unknown_keys(where, t, allowed, p)
  for _, k in ipairs(sorted_keys(t)) do
    if not allowed[k] then
      p[#p + 1] = where
        .. ": unknown key "
        .. tostring(k)
        .. " (allowed: "
        .. compat.concat(sorted_keys(allowed), ", ")
        .. ")"
    end
  end
end

-- env: a name or a non-empty list of names -> list | nil (with a problem)
local function env_list(where, v, p)
  if v == nil then
    return {}
  end
  local list = type(v) == "table" and v or { v }
  if type(v) == "table" and (not is_list(v) or #v == 0) then
    p[#p + 1] = where .. " must be an environment variable name or a list of them"
    return {}
  end
  for _, name in ipairs(list) do
    if not is_env(name) then
      p[#p + 1] = where .. " must be an environment variable name or a list of them"
      return {}
    end
  end
  return list
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

--- ext.reduce(spec) -> a shallow copy the classic checks accept: the keys of this file
-- removed, an env list cut to its first name, a template or missing base URL default
-- replaced by a URL-shaped placeholder. ext.validate checks and normalizes the originals.
function ext.reduce(spec)
  if type(spec) ~= "table" then
    return spec
  end
  local r = copy(spec)
  for k in pairs(ext.TOP) do
    r[k] = nil
  end
  r.error_envelope = nil
  if type(spec.auth) == "table" then
    local a = copy(spec.auth)
    for k in pairs(AUTH_EXT) do
      a[k] = nil
    end
    if a.kind == "basic" then
      a = { kind = "none" }
    end
    if type(a.env) == "table" then
      a.env = a.env[1]
    end
    r.auth = a
  end
  if type(spec.base_url) == "table" then
    local b = copy(spec.base_url)
    for k in pairs(BASE_EXT) do
      b[k] = nil
    end
    if type(b.env) == "table" then
      b.env = b.env[1]
    end
    if
      b.default == nil or (type(b.default) == "string" and string.find(b.default, "{", 1, true))
    then
      b.default = "https://template.invalid"
    end
    r.base_url = b
  end
  return r
end

local function needs_runtime(spec)
  for _, k in ipairs({
    "options",
    "headers",
    "require_one_of",
    "public_operations",
    "oauth",
    "user_agent",
  }) do
    if spec[k] ~= nil then
      return true
    end
  end
  local a = spec.auth
  if type(a) == "table" then
    if a.kind == "basic" or type(a.env) == "table" then
      return true
    end
    for k in pairs(AUTH_EXT) do
      if a[k] ~= nil then
        return true
      end
    end
  end
  local b = spec.base_url
  if type(b) == "table" then
    if type(b.env) == "table" or b.default == nil then
      return true
    end
    if type(b.default) == "string" and string.find(b.default, "{", 1, true) then
      return true
    end
    for k in pairs(BASE_EXT) do
      if b[k] ~= nil then
        return true
      end
    end
  end
  return false
end

-- template references: list of option names, or nil with a problem
local function template_refs(where, text, p)
  if type(text) ~= "string" then
    p[#p + 1] = where .. " must be a string template"
    return nil
  end
  local refs = {}
  for name in string.gmatch(text, "{([%w_]+)}") do
    refs[#refs + 1] = name
  end
  local rest = string.gsub(text, "{[%w_]+}", "")
  if string.find(rest, "[{}]") then
    p[#p + 1] = where .. ": a { or } that is not an {option} reference in " .. text
    return nil
  end
  return refs
end

local function check_option(where, name, o, p)
  if not naming.is_identifier(name) then
    p[#p + 1] = where .. ": option names must be Lua identifiers, got " .. tostring(name)
    return nil
  end
  if type(o) ~= "table" then
    p[#p + 1] = where .. "." .. name .. " must be a table"
    return nil
  end
  unknown_keys(where .. "." .. name, o, OPTION_KEYS, p)
  local n = {
    secret = o.secret == true or nil,
    env = env_list(where .. "." .. name .. ".env", o.env, p),
    required = o.required == true or nil,
    ignore_case = o.ignore_case == true or nil,
    trim_slash = o.trim_slash == true or nil,
    strip_scheme = o.strip_scheme == true or nil,
    doc = o.doc,
    type = o.type or "string",
  }
  for _, k in ipairs({ "secret", "required", "ignore_case", "trim_slash", "strip_scheme" }) do
    if o[k] ~= nil and type(o[k]) ~= "boolean" then
      p[#p + 1] = where .. "." .. name .. "." .. k .. " must be a boolean"
    end
  end
  if o.doc ~= nil and type(o.doc) ~= "string" then
    p[#p + 1] = where .. "." .. name .. ".doc must be a string"
  end
  if n.type ~= "string" and n.type ~= "number" and n.type ~= "boolean" then
    p[#p + 1] = where .. "." .. name .. ".type must be string, number or boolean"
  end
  if n.secret and n.type ~= "string" then
    p[#p + 1] = where .. "." .. name .. ": a secret is a string"
  end
  if o.default ~= nil then
    if type(o.default) ~= "string" then
      p[#p + 1] = where .. "." .. name .. ".default must be a string"
    elseif n.secret then
      p[#p + 1] = where .. "." .. name .. ": a secret has no default in a provider spec"
    end
    n.default = o.default
  end
  if o.invalid ~= nil then
    if o.invalid ~= "error" and o.invalid ~= "default" then
      p[#p + 1] = where .. "." .. name .. '.invalid must be "error" or "default"'
    elseif o.choices == nil then
      p[#p + 1] = where .. "." .. name .. ".invalid needs choices"
    elseif o.invalid == "default" and o.default == nil then
      p[#p + 1] = where .. "." .. name .. ': invalid = "default" needs a default'
    end
    n.invalid = o.invalid
  end
  if o.choices ~= nil then
    if n.secret then
      -- a choice error names the value it got: never a secret's
      p[#p + 1] = where .. "." .. name .. ": a secret option cannot have choices"
    elseif type(o.choices) ~= "table" or next(o.choices) == nil then
      p[#p + 1] = where
        .. "."
        .. name
        .. ".choices must be a list of values or a { value = text } map"
    else
      local list = is_list(o.choices)
      local keys = {}
      for k, v in pairs(o.choices) do
        if type(v) ~= "string" or (not list and type(k) ~= "string") then
          p[#p + 1] = where .. "." .. name .. ".choices must hold strings"
          break
        end
        keys[list and v or k] = true
      end
      if o.default ~= nil and not keys[o.default] then
        p[#p + 1] = where
          .. "."
          .. name
          .. ".default "
          .. tostring(o.default)
          .. " is not one of its choices"
      end
      n.choices = o.choices
    end
  end
  if #n.env == 0 then
    n.env = nil
  end
  return n
end

-- header values: a template, { basic = template }, or a list of those (alternatives)
local function header_values(where, v, p)
  local list
  if type(v) == "string" then
    list = { v }
  elseif type(v) == "table" and v.basic ~= nil then
    list = { v }
  elseif is_list(v) and #v > 0 then
    list = v
  else
    p[#p + 1] = where .. " must be a template, { basic = template } or a list of them"
    return {}
  end
  local out = {}
  for i, alt in ipairs(list) do
    local w = #list > 1 and (where .. "[" .. i .. "]") or where
    if type(alt) == "string" then
      out[#out + 1] = { template = alt }
    elseif type(alt) == "table" then
      unknown_keys(w, alt, { basic = true }, p)
      if type(alt.basic) ~= "string" then
        p[#p + 1] = w .. ".basic must be a template"
      else
        out[#out + 1] = { template = alt.basic, basic = true }
      end
    else
      p[#p + 1] = w .. " must be a template or { basic = template }"
    end
  end
  return out
end

local function check_pointer_list(where, v, p)
  if v == nil then
    return nil
  end
  local list = type(v) == "table" and v or { v }
  if type(v) == "table" and (not is_list(v) or #v == 0) then
    p[#p + 1] = where .. " must be a JSON pointer or a list of them"
    return nil
  end
  for _, ptr in ipairs(list) do
    if not is_pointer(ptr) then
      p[#p + 1] = where .. " must be a JSON pointer (/a/b) or a list of them"
      return nil
    end
  end
  return list
end

local function load_glue(path, p)
  local f = io.open(path, "rb")
  if not f then
    p[#p + 1] = "provider spec glue: cannot read " .. path
    return nil
  end
  local text = f:read("*a")
  f:close()
  local chunk, cerr = compat.load(text, "@" .. path)
  if not chunk then
    p[#p + 1] = "provider spec glue " .. path .. ": " .. tostring(cerr)
    return nil
  end
  local ok, mod = compat.pcall(chunk, "glue")
  if not ok then
    p[#p + 1] = "provider spec glue " .. path .. " raised: " .. tostring(mod)
    return nil
  end
  if type(mod) ~= "table" then
    p[#p + 1] = "provider spec glue " .. path .. " must return a table of functions"
    return nil
  end
  local hooks = {}
  for _, k in ipairs(sorted_keys(mod)) do
    if not ext.HOOKS[k] then
      p[#p + 1] = "provider spec glue "
        .. path
        .. ": unknown function "
        .. tostring(k)
        .. " (allowed: "
        .. compat.concat(sorted_keys(ext.HOOKS), ", ")
        .. ")"
    elseif type(mod[k]) ~= "function" then
      p[#p + 1] = "provider spec glue " .. path .. ": " .. k .. " must be a function"
    else
      hooks[k] = true
    end
  end
  return { path = path, source = text, hooks = hooks }
end

local function join(dir, path)
  if string.sub(path, 1, 1) == "/" or dir == nil or dir == "" then
    return path
  end
  return dir .. "/" .. path
end

-- options the classic spec declares (auth.from, base_url.option), for the docs
local function classic_docs(out)
  local docs = {}
  if out.auth.kind ~= "none" then
    docs[#docs + 1] = {
      name = out.auth.from,
      secret = true,
      required = true,
      env = out.auth.env and { out.auth.env } or {},
    }
  end
  docs[#docs + 1] = {
    name = out.base_url.option,
    env = out.base_url.env and { out.base_url.env } or {},
    default = out.base_url.default,
    base_url = true,
  }
  return docs
end

--- ext.validate(raw, out, p, opts) : checks the keys of this file in the raw spec and
-- fills `out` (the normalized spec): out.runtime (the data for rest.new{ provider }),
-- out.client_options, out.option_docs, out.error_envelope, out.error_classes,
-- out.unknown_fields, out.transform_response, out.glue, out.public_operations.
-- opts.dir: the directory a relative glue path is read from.
function ext.validate(raw, out, p, opts)
  opts = opts or {}
  if type(raw) ~= "table" then
    return
  end

  -- error envelope (both forms)
  if raw.error_envelope ~= nil then
    local e = raw.error_envelope
    if type(e) ~= "table" then
      p[#p + 1] =
        "provider spec: error_envelope must be { code = <pointer(s)>, message = <pointer(s)> }"
    else
      unknown_keys(
        "provider spec error_envelope",
        e,
        { code = true, message = true, non_empty = true },
        p
      )
      out.error_envelope = {
        code = check_pointer_list("provider spec error_envelope.code", e.code, p),
        message = check_pointer_list("provider spec error_envelope.message", e.message, p),
        non_empty = e.non_empty == true or nil,
      }
    end
  end

  -- error classes for the status map
  out.error_classes = {}
  if raw.error_classes ~= nil then
    if type(raw.error_classes) ~= "table" then
      p[#p + 1] = "provider spec: error_classes must be { Tag = { categories = { ... } } }"
    else
      for _, tag in ipairs(sorted_keys(raw.error_classes)) do
        local c = raw.error_classes[tag]
        local where = "provider spec error_classes." .. tostring(tag)
        if not is_tag(tag) then
          p[#p + 1] = "provider spec error_classes: " .. tostring(tag) .. " is not an error tag"
        elseif type(c) ~= "table" then
          p[#p + 1] = where .. " must be { categories = { ... }, retryable = bool }"
        else
          unknown_keys(where, c, { categories = true, retryable = true }, p)
          local cats = c.categories or {}
          if not is_list(cats) then
            p[#p + 1] = where .. ".categories must be a list"
            cats = {}
          end
          for _, cat in ipairs(cats) do
            if not CATEGORIES[cat] then
              p[#p + 1] = where .. ": unknown category " .. tostring(cat)
            end
          end
          if c.retryable ~= nil and type(c.retryable) ~= "boolean" then
            p[#p + 1] = where .. ".retryable must be a boolean"
          end
          out.error_classes[#out.error_classes + 1] =
            { tag = tag, categories = cats, retryable = c.retryable == true or nil }
        end
      end
    end
  end

  if raw.unknown_fields ~= nil then
    if type(raw.unknown_fields) ~= "table" then
      p[#p + 1] = "provider spec: unknown_fields must be { field = <pointer> }"
    else
      local reserved =
        { status = true, code = true, message = true, body = true, headers = true, tag = true }
      for k, v in pairs(raw.unknown_fields) do
        if not naming.is_identifier(k) or reserved[k] then
          p[#p + 1] = "provider spec unknown_fields: " .. tostring(k) .. " is not a free field name"
        elseif not is_pointer(v) then
          p[#p + 1] = "provider spec unknown_fields." .. k .. " must be a JSON pointer"
        end
      end
      out.unknown_fields = raw.unknown_fields
    end
  end

  if raw.transform_response ~= nil then
    local list = raw.transform_response
    if type(list) == "string" or (type(list) == "table" and list.unwrap ~= nil) then
      list = { list }
    end
    if not is_list(list) then
      p[#p + 1] =
        'provider spec: transform_response must be a list of "strip_nulls" | { unwrap = key }'
    else
      for i, tr in ipairs(list) do
        local where = "provider spec transform_response[" .. i .. "]"
        if type(tr) == "table" then
          unknown_keys(where, tr, { unwrap = true, skip_paginated = true }, p)
          if type(tr.unwrap) ~= "string" or tr.unwrap == "" then
            p[#p + 1] = where .. ".unwrap must be a member name"
          end
        elseif tr ~= "strip_nulls" then
          p[#p + 1] = where .. ' must be "strip_nulls" or { unwrap = key, skip_paginated = bool }'
        end
      end
      out.transform_response = list
    end
  end

  if raw.glue ~= nil then
    if type(raw.glue) ~= "string" or not string.find(raw.glue, "%.lua$") then
      p[#p + 1] = "provider spec: glue must be the path of a .lua file (relative to the spec)"
    else
      out.glue = load_glue(join(opts.dir, raw.glue), p)
      if out.glue then
        for _, k in ipairs({ "error_envelope", "transform_response", "classify_error" }) do
          if out.glue.hooks[k] and raw[k] ~= nil then
            p[#p + 1] = "provider spec: " .. k .. " is both a spec key and a glue function"
          end
        end
      end
    end
  end

  out.option_docs = classic_docs(out)
  if not needs_runtime(raw) then
    return
  end

  ---------------------------------------------------------------------------------
  -- the provider runtime data
  ---------------------------------------------------------------------------------
  local options, order = {}, {}
  local function declare(name, o, where)
    if options[name] then
      p[#p + 1] = where .. ": option " .. name .. " is declared twice"
      return
    end
    options[name] = o
    order[#order + 1] = name
  end
  local common = {}
  for _, k in ipairs(require("distilled.client").COMMON_OPTIONS) do
    common[k] = true
  end

  if raw.options ~= nil then
    if type(raw.options) ~= "table" or is_list(raw.options) and #raw.options > 0 then
      p[#p + 1] = "provider spec: options must be { name = { ... } }"
    else
      for _, name in ipairs(sorted_keys(raw.options)) do
        local o = check_option("provider spec options", name, raw.options[name], p)
        if o then
          if common[name] then
            p[#p + 1] = "provider spec options: "
              .. name
              .. " is a common client option"
              .. (name == "user_agent" and " (use the user_agent key)" or "")
          end
          declare(name, o, "provider spec options")
        end
      end
    end
  end

  -- auth -> an option and a header
  local headers = {}
  local auth = type(raw.auth) == "table" and raw.auth or { kind = "none" }
  local a = out.auth
  if auth.kind == "basic" then
    unknown_keys(
      "provider spec auth",
      auth,
      { kind = true, username = true, password = true, optional = true },
      p
    )
    for _, k in ipairs({ "username", "password" }) do
      if not naming.is_identifier(auth[k]) then
        p[#p + 1] = "provider spec auth." .. k .. " must name an option declared in options"
      elseif not options[auth[k]] then
        p[#p + 1] = "provider spec auth." .. k .. ": " .. auth[k] .. " is not declared in options"
      end
    end
    if options[auth.password] and not options[auth.password].secret then
      p[#p + 1] = "provider spec auth.password: option " .. auth.password .. " must be secret"
    end
    a = { kind = "basic", username = auth.username, password = auth.password }
    out.auth = a
    if naming.is_identifier(auth.username) and naming.is_identifier(auth.password) then
      headers.authorization = {
        { template = "{" .. auth.username .. "}:{" .. auth.password .. "}", basic = true },
      }
    end
  elseif auth.kind == "bearer" or auth.kind == "header" then
    if auth.prefix ~= nil and type(auth.prefix) ~= "string" then
      p[#p + 1] = "provider spec auth.prefix must be a string"
    end
    if auth.optional ~= nil and type(auth.optional) ~= "boolean" then
      p[#p + 1] = "provider spec auth.optional must be a boolean"
    end
    if auth.kind == "bearer" and auth.prefix ~= nil then
      p[#p + 1] = 'provider spec auth.prefix is for kind = "header" (bearer is "Bearer ")'
    end
    local env = env_list("provider spec auth.env", auth.env, p)
    if a.from and options[a.from] then
      p[#p + 1] = "provider spec: auth.from " .. a.from .. " is also declared in options"
    elseif a.from then
      declare(a.from, {
        secret = true,
        env = #env > 0 and env or nil,
        required = not auth.optional or nil,
        type = "string",
      }, "provider spec auth")
    end
    a.env = env[1]
    a.env_list = env
    a.optional = auth.optional == true or nil
    local name = auth.kind == "bearer" and "authorization" or a.header
    local prefix = auth.kind == "bearer" and "Bearer " or (auth.prefix or "")
    if name then
      headers[name] = { { template = prefix .. "{" .. tostring(a.from) .. "}" } }
    end
  end

  -- base URL -> an option
  local braw = type(raw.base_url) == "table" and raw.base_url or { default = raw.base_url }
  local b = out.base_url
  local benv = env_list("provider spec base_url.env", braw.env, p)
  if options[b.option] then
    p[#p + 1] = "provider spec: base_url.option "
      .. b.option
      .. " is declared in options; declare its env in base_url"
  else
    declare(
      b.option,
      { env = #benv > 0 and benv or nil, type = "string" },
      "provider spec base_url"
    )
  end
  local base_rt = { option = b.option }
  if braw.default ~= nil then
    local refs = template_refs("provider spec base_url.default", braw.default, p)
    if refs and type(braw.default) == "string" then
      local probe = string.gsub(braw.default, "{[%w_]+}", "x")
      if #refs == 0 and not string.find(probe, "^https?://[^/]") then
        p[#p + 1] = "provider spec base_url.default must be an http(s) URL"
      elseif string.sub(braw.default, -1) == "/" then
        p[#p + 1] = "provider spec base_url.default must not end with /"
      end
      for _, r in ipairs(refs) do
        if r == b.option then
          p[#p + 1] = "provider spec base_url.default cannot use its own option {" .. r .. "}"
        end
      end
    end
    base_rt.default = braw.default
  end
  for _, k in ipairs({ "trim_slash" }) do
    if braw[k] ~= nil and type(braw[k]) ~= "boolean" then
      p[#p + 1] = "provider spec base_url." .. k .. " must be a boolean"
    end
  end
  base_rt.trim_slash = braw.trim_slash == true or nil
  if braw.ensure_suffix ~= nil then
    if type(braw.ensure_suffix) ~= "string" or not string.find(braw.ensure_suffix, "^/[^/]") then
      p[#p + 1] = "provider spec base_url.ensure_suffix must be a path like /api/v1"
    end
    base_rt.ensure_suffix = braw.ensure_suffix
  end
  if braw.origin ~= nil then
    local o = braw.origin
    if o == true then
      o = {}
    end
    if type(o) ~= "table" then
      p[#p + 1] = "provider spec base_url.origin must be true or { label, example }"
      o = {}
    end
    unknown_keys("provider spec base_url.origin", o, { label = true, example = true }, p)
    base_rt.origin = {
      label = o.label or (out.title .. " base URL"),
      example = o.example or (base_rt.default or "https://api.example.com"),
    }
  end
  out.base_url = {
    default = braw.default or "",
    option = b.option,
    env = benv[1],
    env_list = benv,
    required = braw.default == nil or nil,
  }

  -- headers
  if raw.headers ~= nil then
    if type(raw.headers) ~= "table" then
      p[#p + 1] = "provider spec: headers must be { [name] = template | { ... } }"
    else
      for _, name in ipairs(sorted_keys(raw.headers)) do
        local where = "provider spec headers[" .. tostring(name) .. "]"
        if type(name) ~= "string" or not string.find(name, "^[A-Za-z0-9-]+$") then
          p[#p + 1] = where .. ": not a header name"
        else
          local lower = string.lower(name)
          if lower == "user-agent" then
            p[#p + 1] = where .. ": use the user_agent key (the user_agent client option must win)"
          elseif headers[lower] then
            p[#p + 1] = where .. ": the header is already set (by auth or another spelling)"
          else
            headers[lower] = header_values(where, raw.headers[name], p)
          end
        end
      end
    end
  end
  local header_rt = {}
  for _, name in ipairs(sorted_keys(headers)) do
    local secret = false
    for _, alt in ipairs(headers[name]) do
      for _, r in
        ipairs(template_refs("provider spec headers[" .. name .. "]", alt.template, p) or {})
      do
        if not options[r] then
          p[#p + 1] = "provider spec headers[" .. name .. "]: {" .. r .. "} is not an option"
        elseif options[r].secret then
          secret = true
        end
      end
    end
    header_rt[#header_rt + 1] = { name = name, values = headers[name], secret = secret or nil }
  end
  for _, r in
    ipairs(
      base_rt.default and template_refs("provider spec base_url.default", base_rt.default, {}) or {}
    )
  do
    if not options[r] then
      p[#p + 1] = "provider spec base_url.default: {" .. r .. "} is not an option"
    elseif options[r].secret then
      p[#p + 1] = "provider spec base_url.default: {" .. r .. "} is a secret"
    end
  end

  local rt = {
    title = out.title,
    options = {},
    headers = header_rt,
    base_url = base_rt,
  }

  if raw.require_one_of ~= nil then
    local list = raw.require_one_of
    if not is_list(list) or #list < 2 then
      p[#p + 1] = "provider spec: require_one_of must list two or more options"
    else
      for _, name in ipairs(list) do
        if not options[name] then
          p[#p + 1] = "provider spec require_one_of: " .. tostring(name) .. " is not an option"
        end
      end
      rt.require_one_of = list
    end
  end

  if raw.public_operations ~= nil then
    if not is_list(raw.public_operations) then
      p[#p + 1] = "provider spec: public_operations must be a list of operation names"
    else
      rt.anonymous = {}
      for _, name in ipairs(raw.public_operations) do
        if type(name) ~= "string" then
          p[#p + 1] = "provider spec public_operations: names must be strings"
        else
          rt.anonymous[name] = true
        end
      end
      out.public_operations = raw.public_operations
    end
  end

  if raw.user_agent ~= nil then
    local ua = raw.user_agent
    if type(ua) == "string" then
      ua = { default = ua }
    end
    if type(ua) ~= "table" then
      p[#p + 1] = "provider spec: user_agent must be a string or { default, env }"
    else
      unknown_keys("provider spec user_agent", ua, { default = true, env = true }, p)
      if type(ua.default) ~= "string" or ua.default == "" then
        p[#p + 1] = "provider spec user_agent.default must be a string"
      end
      local uenv = env_list("provider spec user_agent.env", ua.env, p)
      rt.user_agent = { default = ua.default, env = #uenv > 0 and uenv or nil }
    end
  end

  if raw.oauth ~= nil then
    local o = raw.oauth
    if type(o) ~= "table" then
      p[#p + 1] = "provider spec: oauth must be a table"
    else
      unknown_keys("provider spec oauth", o, OAUTH_KEYS, p)
      for _, k in ipairs({ "client_id", "client_secret", "into" }) do
        if not options[o[k]] then
          p[#p + 1] = "provider spec oauth." .. k .. " must name an option"
        end
      end
      if options[o.client_secret] and not options[o.client_secret].secret then
        p[#p + 1] = "provider spec oauth.client_secret: option "
          .. o.client_secret
          .. " must be secret"
      end
      if options[o.into] and not options[o.into].secret then
        p[#p + 1] = "provider spec oauth.into: option " .. o.into .. " must be secret"
      end
      for _, r in ipairs(template_refs("provider spec oauth.token_url", o.token_url, p) or {}) do
        if not options[r] then
          p[#p + 1] = "provider spec oauth.token_url: {" .. r .. "} is not an option"
        end
      end
      if o.auth ~= nil and o.auth ~= "basic" and o.auth ~= "form" then
        p[#p + 1] = 'provider spec oauth.auth must be "basic" or "form"'
      end
      if o.reuse ~= nil and o.reuse ~= "window" and o.reuse ~= "half" then
        p[#p + 1] = 'provider spec oauth.reuse must be "window" or "half"'
      end
      if o.scope ~= nil and not options[o.scope] then
        p[#p + 1] = "provider spec oauth.scope must name an option"
      end
      for field, opt in pairs(o.extra or {}) do
        if type(field) ~= "string" or not options[opt] then
          p[#p + 1] = "provider spec oauth.extra." .. tostring(field) .. " must name an option"
        end
      end
      for _, k in ipairs({ "default_ttl_s", "refresh_window_s" }) do
        if o[k] ~= nil and (type(o[k]) ~= "number" or o[k] <= 0) then
          p[#p + 1] = "provider spec oauth." .. k .. " must be a positive number"
        end
      end
      rt.oauth = {
        token_url = o.token_url,
        client_id = o.client_id,
        client_secret = o.client_secret,
        into = o.into,
        auth = o.auth or "basic",
        scope = o.scope,
        extra = o.extra,
        default_ttl_s = o.default_ttl_s,
        refresh_window_s = o.refresh_window_s,
        reuse = o.reuse,
        required = o.required == true or nil,
        label = o.label,
      }
    end
  end

  -- runtime options, client options, docs
  local client_options, docs = {}, {}
  table.sort(order)
  for _, name in ipairs(order) do
    local o = options[name]
    rt.options[name] = {
      secret = o.secret,
      env = o.env,
      default = o.default,
      required = o.required,
      choices = o.choices,
      ignore_case = o.ignore_case,
      invalid = o.invalid,
      trim_slash = o.trim_slash,
      strip_scheme = o.strip_scheme,
    }
    client_options[name] = o.secret and { secret = true } or { type = o.type }
    docs[#docs + 1] = {
      name = name,
      secret = o.secret,
      required = o.required,
      env = o.env or {},
      default = name == b.option and base_rt.default or o.default,
      choices = o.choices,
      doc = o.doc,
      base_url = name == b.option or nil,
    }
  end
  if b.option and base_rt.default == nil then
    for _, d in ipairs(docs) do
      if d.name == b.option then
        d.required = true
      end
    end
  end
  out.runtime = rt
  out.client_options = client_options
  out.option_docs = docs
end

return ext
