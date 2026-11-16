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
--     error_envelope = { code = "/code", message = "/message" },   -- JSON pointers, optional
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
--     pagination = { items_fallback = "items" },     -- items path when the trait has none
--     allow_unsupported = { "<gap>" },       -- emit operations the runtime refuses at
--                                            -- call time (SdkError) instead of failing
--                                            -- (provider.UNSUPPORTED; empty today)
--   }
local compat = require("distilled.compat")
local naming = require("distilled.gen.naming")

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
}

-- Runtime gaps a provider may acknowledge (see allow_unsupported above). None today:
-- multipart bodies were the only one, and request.build encodes them since task 08. The
-- mechanism stays for the next gap; a spec may add an entry to exercise it.
provider.UNSUPPORTED = {}

-- Gaps that were closed: listing one is a stale provider spec, reported as such.
provider.CLOSED_GAPS = {
  multipart = "request.build encodes multipart bodies now; remove it from allow_unsupported",
}

--- provider.validate(spec) -> normalized spec | nil, message
-- Normalized: base_url is always a table, auth always has kind; defaults filled in.
function provider.validate(spec)
  local p = {}
  if type(spec) ~= "table" then
    return nil, "provider spec: expected a table, got " .. type(spec)
  end
  check_keys("provider spec", spec, TOP, p)

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

  -- base_url
  local base = spec.base_url
  if type(base) == "string" then
    base = { default = base }
  end
  if type(base) ~= "table" then
    p[#p + 1] = "provider spec: base_url must be a URL string or { default, option, env }"
    base = {}
  else
    check_keys("provider spec base_url", base, { default = true, option = true, env = true }, p)
    if type(base.default) ~= "string" or not string.find(base.default, "^https?://[^/]") then
      p[#p + 1] = "provider spec base_url.default must be an http(s) URL"
    elseif string.sub(base.default, -1) == "/" then
      p[#p + 1] = "provider spec base_url.default must not end with /"
    end
    if base.option ~= nil and not naming.is_identifier(base.option) then
      p[#p + 1] = "provider spec base_url.option must be an identifier"
    end
    if base.env ~= nil and not is_env(base.env) then
      p[#p + 1] = "provider spec base_url.env must be an environment variable name"
    end
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
    p[#p + 1] = "provider spec auth.kind must be bearer, header or none, got "
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

  if spec.error_envelope ~= nil then
    if type(spec.error_envelope) ~= "table" then
      p[#p + 1] = "provider spec: error_envelope must be { code = <pointer>, message = <pointer> }"
    else
      check_keys(
        "provider spec error_envelope",
        spec.error_envelope,
        { code = true, message = true },
        p
      )
      for _, k in ipairs({ "code", "message" }) do
        local v = spec.error_envelope[k]
        if v ~= nil and not is_pointer(v) then
          p[#p + 1] = "provider spec error_envelope." .. k .. " must be a JSON pointer (/a/b)"
        end
      end
      out.error_envelope =
        { code = spec.error_envelope.code, message = spec.error_envelope.message }
    end
  end
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
  check_keys("provider spec pagination", pg, { items_fallback = true }, p)
  if pg.items_fallback ~= nil and type(pg.items_fallback) ~= "string" then
    p[#p + 1] = "provider spec pagination.items_fallback must be a string"
  end
  out.pagination = { items_fallback = pg.items_fallback or "items" }

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
  local out, verr = provider.validate(spec)
  if not out then
    return nil, path .. ":\n" .. verr
  end
  return out
end

return provider
