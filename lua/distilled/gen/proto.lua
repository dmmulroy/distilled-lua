-- Proto-sourced providers (task 23): the provider spec's `proto` section, the gRPC
-- descriptors each generated client carries, and the client module (init.lua) that
-- wires distilled.protocol.grpc or distilled.protocol.connect.
--
--   proto = {
--     wire = "grpc" | "grpc-web" | "connect",
--     descriptors = "descriptors.ts",       -- grpc wires: Distilled's src/descriptors.ts
--                                           -- (or a .json of it), relative to the model's
--                                           -- directory; `dl models sync` copies it there
--     error_matchers_trait = "com.modal.protocols#errorMatchers",  -- read as the
--                                           -- error matchers trait (Distilled's
--                                           -- SdkSpec.errorMatchersTrait)
--     http2 = false | true | "<option>",    -- HTTP/2 always, or when the option is set
--     options = { [name] = { secret, env = "A" | { "A", "B" }, default, required, doc } },
--                                           -- client options; a default may name other
--                                           -- options: "https://{region}.compute.x.com"
--     base_url = "{base_url}"               -- a template over the options, or
--              | { by_prefix = { { "/pkg.", "{other_base_url}" }, ... }, default = "..." }
--              | { when = "domain", cases = { ["e2b.app"] = "..." }, default = "..." },
--     headers = { { "x-modal-token-id", "{token_id}", unless = "bearer_token" }, ... },
--     require_one_of = { "api_key", "access_token" },
--     empty_json_body = true,               -- connect: post {} for an empty message
--     error_envelope = { code = "/code", message = { "/message", "/details" } },
--     unknown_fields = { details = "/details" },   -- extra fields of the unknown error
--     models = { [model] = { options, base_url, headers, require_one_of } },
--                                           -- per-model changes (e2b's envd modules);
--                                           -- options merge (false removes one), the
--                                           -- others replace
--   }
--
-- The top-level `auth` and `base_url` keys still apply: they become options (and an
-- authorization header) under the proto ones, which win by name. (The `rpc` key is
-- task 22's: operations without http traits, gen/rpc.lua.)
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local json = require("distilled.json")
local naming = require("distilled.gen.naming")

local proto = {}

local WIRES = { grpc = true, ["grpc-web"] = true, connect = true }

local KEYS = {
  wire = true,
  descriptors = true,
  error_matchers_trait = true,
  http2 = true,
  options = true,
  base_url = true,
  headers = true,
  require_one_of = true,
  empty_json_body = true,
  error_envelope = true,
  unknown_fields = true,
  models = true,
}
local OPTION_KEYS = { secret = true, env = true, default = true, required = true, doc = true }
local MODEL_KEYS =
  { options = true, base_url = true, headers = true, require_one_of = true, empty_json_body = true }

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

local function is_env(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_pointer(s)
  return type(s) == "string" and (s == "" or string.sub(s, 1, 1) == "/")
end

local function check_template(where, s, p)
  if type(s) ~= "string" then
    p[#p + 1] = where .. " must be a string"
    return
  end
  for name in string.gmatch(s, "{([^}]*)}") do
    if not naming.is_identifier(name) then
      p[#p + 1] = where .. ": {" .. name .. "} is not an option name"
    end
  end
end

local function check_options(where, options, p, allow_false)
  if type(options) ~= "table" then
    p[#p + 1] = where .. " must be { [name] = { secret, env, default, required, doc } }"
    return
  end
  for _, name in ipairs(sorted_keys(options)) do
    local o = options[name]
    local w = where .. "." .. tostring(name)
    if not naming.is_identifier(name) then
      p[#p + 1] = w .. ": not a Lua identifier"
    elseif o == false and allow_false then
      -- removes the option
    elseif type(o) ~= "table" then
      p[#p + 1] = w .. " must be a table"
    else
      unknown_keys(w, o, OPTION_KEYS, p)
      local env = o.env
      if env ~= nil then
        local list = type(env) == "table" and env or { env }
        for _, e in ipairs(list) do
          if not is_env(e) then
            p[#p + 1] = w .. ".env must name environment variables"
          end
        end
      end
      if o.default ~= nil then
        if type(o.default) == "string" then
          check_template(w .. ".default", o.default, p)
        elseif type(o.default) ~= "number" and type(o.default) ~= "boolean" then
          p[#p + 1] = w .. ".default must be a string, number or boolean"
        end
      end
      if o.doc ~= nil and type(o.doc) ~= "string" then
        p[#p + 1] = w .. ".doc must be a string"
      end
    end
  end
end

local function check_base_url(where, b, p)
  if type(b) == "string" then
    check_template(where, b, p)
  elseif type(b) == "table" then
    unknown_keys(where, b, { by_prefix = true, when = true, cases = true, default = true }, p)
    check_template(where .. ".default", b.default, p)
    for i, entry in ipairs(b.by_prefix or {}) do
      if type(entry) ~= "table" or type(entry[1]) ~= "string" then
        p[#p + 1] = where .. ".by_prefix[" .. i .. "] must be { prefix, template }"
      else
        check_template(where .. ".by_prefix[" .. i .. "]", entry[2], p)
      end
    end
    if b.when ~= nil and not naming.is_identifier(b.when) then
      p[#p + 1] = where .. ".when must name an option"
    end
    for k, v in pairs(b.cases or {}) do
      check_template(where .. ".cases[" .. tostring(k) .. "]", v, p)
    end
  else
    p[#p + 1] = where .. " must be a template or { by_prefix, when, cases, default }"
  end
end

local function check_headers(where, h, p)
  if type(h) ~= "table" then
    p[#p + 1] = where .. " must be a list of { header, template, unless? }"
    return
  end
  for i, rule in ipairs(h) do
    local w = where .. "[" .. i .. "]"
    if type(rule) ~= "table" or type(rule[1]) ~= "string" then
      p[#p + 1] = w .. " must be { header, template, unless? }"
    else
      if not string.find(rule[1], "^[A-Za-z0-9-]+$") then
        p[#p + 1] = w .. ": " .. rule[1] .. " is not a header name"
      end
      check_template(w, rule[2], p)
      for k in pairs(rule) do
        if k ~= 1 and k ~= 2 and k ~= "unless" then
          p[#p + 1] = w .. ": unknown key " .. tostring(k)
        end
      end
      if rule.unless ~= nil and not naming.is_identifier(rule.unless) then
        p[#p + 1] = w .. ".unless must name an option"
      end
    end
  end
end

local function check_one_of(where, list, p)
  if list == false then
    return
  end
  if type(list) ~= "table" or #list == 0 then
    p[#p + 1] = where .. " must be a list of option names"
    return
  end
  for _, n in ipairs(list) do
    if not naming.is_identifier(n) then
      p[#p + 1] = where .. " must be a list of option names"
    end
  end
end

--- proto.validate(proto_spec, spec) -> normalized proto_spec | nil, problems (a list)
-- spec is the provider spec validated so far (auth, base_url).
function proto.validate(r, spec)
  local p = {}
  if type(r) ~= "table" then
    return nil, { "provider spec proto must be a table" }
  end
  unknown_keys("provider spec proto", r, KEYS, p)
  if not WIRES[r.wire] then
    p[#p + 1] = "provider spec proto.wire must be grpc, grpc-web or connect"
  end
  if r.wire == "connect" then
    if r.descriptors ~= nil or r.http2 ~= nil then
      p[#p + 1] = "provider spec proto: descriptors and http2 are for the grpc wires"
    end
  elseif type(r.descriptors) ~= "string" or r.descriptors == "" then
    p[#p + 1] = "provider spec proto.descriptors must name the descriptors file (descriptors.ts)"
  end
  if
    r.error_matchers_trait ~= nil
    and (
      type(r.error_matchers_trait) ~= "string"
      or not string.find(r.error_matchers_trait, "#", 1, true)
    )
  then
    p[#p + 1] = "provider spec proto.error_matchers_trait must be a trait id (ns#name)"
  end
  if r.http2 ~= nil and type(r.http2) ~= "boolean" and not naming.is_identifier(r.http2) then
    p[#p + 1] = "provider spec proto.http2 must be a boolean or an option name"
  end
  if r.options ~= nil then
    check_options("provider spec proto.options", r.options, p, false)
  end
  if r.base_url ~= nil then
    check_base_url("provider spec proto.base_url", r.base_url, p)
  end
  if r.headers ~= nil then
    check_headers("provider spec proto.headers", r.headers, p)
  end
  if r.require_one_of ~= nil then
    check_one_of("provider spec proto.require_one_of", r.require_one_of, p)
  end
  if r.empty_json_body ~= nil and type(r.empty_json_body) ~= "boolean" then
    p[#p + 1] = "provider spec proto.empty_json_body must be a boolean"
  end
  if r.error_envelope ~= nil then
    if type(r.error_envelope) ~= "table" then
      p[#p + 1] = "provider spec proto.error_envelope must be { code, message }"
    else
      unknown_keys(
        "provider spec proto.error_envelope",
        r.error_envelope,
        { code = true, message = true },
        p
      )
      for _, k in ipairs({ "code", "message" }) do
        local v = r.error_envelope[k]
        local list = type(v) == "table" and v or { v }
        if v ~= nil then
          for _, ptr in ipairs(list) do
            if not is_pointer(ptr) then
              p[#p + 1] = "provider spec proto.error_envelope." .. k .. " must be JSON pointers"
            end
          end
        end
      end
    end
  end
  if r.unknown_fields ~= nil then
    if type(r.unknown_fields) ~= "table" then
      p[#p + 1] = "provider spec proto.unknown_fields must be { field = pointer }"
    else
      for k, v in pairs(r.unknown_fields) do
        if not naming.is_identifier(k) or not is_pointer(v) then
          p[#p + 1] = "provider spec proto.unknown_fields must be { field = pointer }"
        end
      end
    end
  end
  if r.models ~= nil then
    if type(r.models) ~= "table" then
      p[#p + 1] = "provider spec proto.models must be { [model] = { ... } }"
    else
      for _, name in ipairs(sorted_keys(r.models)) do
        local mo = r.models[name]
        local w = "provider spec proto.models." .. tostring(name)
        if type(mo) ~= "table" then
          p[#p + 1] = w .. " must be a table"
        else
          unknown_keys(w, mo, MODEL_KEYS, p)
          if mo.options ~= nil then
            check_options(w .. ".options", mo.options, p, true)
          end
          if mo.base_url ~= nil then
            check_base_url(w .. ".base_url", mo.base_url, p)
          end
          if mo.headers ~= nil then
            check_headers(w .. ".headers", mo.headers, p)
          end
          if mo.require_one_of ~= nil then
            check_one_of(w .. ".require_one_of", mo.require_one_of, p)
          end
          if mo.empty_json_body ~= nil and type(mo.empty_json_body) ~= "boolean" then
            p[#p + 1] = w .. ".empty_json_body must be a boolean"
          end
        end
      end
    end
  end
  if
    spec.status_map ~= nil
    or spec.classify_error ~= nil
    or spec.protocol ~= nil
    or spec.rpc ~= nil
  then
    p[#p + 1] = "provider spec proto: status_map, classify_error, protocol and rpc (task 22's) "
      .. "are not supported with proto"
  end
  if #p > 0 then
    return nil, p
  end
  return r
end

-- the effective settings, header rules, base URL and one-of list for a model
function proto.effective(spec)
  local r = spec.proto
  local mo = (r.models or {})[spec.model_name or ""] or {}
  local settings, headers = {}, {}
  local auth = spec.auth
  if auth.kind ~= "none" then
    settings[auth.from] = { secret = true, env = auth.env and { auth.env } or nil, required = true }
    if auth.kind == "bearer" then
      headers[#headers + 1] = { "authorization", "Bearer {" .. auth.from .. "}" }
    else
      headers[#headers + 1] = { auth.header, "{" .. auth.from .. "}" }
    end
  end
  local b = spec.base_url
  settings[b.option] = { env = b.env and { b.env } or nil, default = b.default }
  for name, o in pairs(r.options or {}) do
    settings[name] = o
  end
  for name, o in pairs(mo.options or {}) do
    if o == false then
      settings[name] = nil
    else
      settings[name] = o
    end
  end
  local out = {}
  for name, o in pairs(settings) do
    local c = {}
    for k, v in pairs(o) do
      if k ~= "doc" then
        c[k] = v
      end
    end
    if type(c.env) == "string" then
      c.env = { c.env }
    end
    if c.env then
      c.env = emit.list(c.env)
    end
    out[name] = c
  end
  for _, rule in ipairs(r.headers or {}) do
    headers[#headers + 1] = rule
  end
  if mo.headers then
    headers = mo.headers
  end
  local one_of = r.require_one_of
  if mo.require_one_of ~= nil then
    one_of = mo.require_one_of
  end
  local empty = r.empty_json_body == true
  if mo.empty_json_body ~= nil then
    empty = mo.empty_json_body
  end
  return {
    settings = out,
    docs = settings,
    headers = headers,
    base_url = mo.base_url or r.base_url or ("{" .. b.option .. "}"),
    require_one_of = one_of or nil,
    empty_json_body = empty,
  }
end

---------------------------------------------------------------------------------------
-- descriptors
---------------------------------------------------------------------------------------

--- proto.parse_descriptors(text, path) -> descriptors | nil, message
-- A descriptors.ts as Distilled's convert scripts write it (`JSON.parse('<json>')` or
-- `JSON.parse("<json string literal>")`), or the JSON itself.
function proto.parse_descriptors(text, path)
  local json_text
  if string.find(text, "^%s*{") then
    json_text = text
  else
    local at = string.find(text, "JSON.parse(", 1, true)
    if not at then
      return nil, path .. ": no JSON.parse( in the descriptors file"
    end
    local q = string.match(text, "^%s*(['\"])", at + 11)
    if q == "'" then
      local s = string.find(text, "'", at + 11, true)
      local e = string.find(text, "'", s + 1, true)
      if not e then
        return nil, path .. ": unterminated descriptors string"
      end
      json_text = string.sub(text, s + 1, e - 1)
    elseif q == '"' then
      local s = string.find(text, '"', at + 11, true)
      local e = s + 1
      while true do
        local c = string.sub(text, e, e)
        if c == "" then
          return nil, path .. ": unterminated descriptors string"
        elseif c == "\\" then
          e = e + 2
        elseif c == '"' then
          break
        else
          e = e + 1
        end
      end
      json_text = json.decode(string.sub(text, s, e))
      if type(json_text) ~= "string" then
        return nil, path .. ": the descriptors string literal is not JSON"
      end
    else
      return nil, path .. ": JSON.parse( is not followed by a string"
    end
  end
  local d = json.decode(json_text)
  if type(d) ~= "table" or type(d.messages) ~= "table" or type(d.methods) ~= "table" then
    return nil, path .. ": not a descriptor table { messages, enums, methods }"
  end
  d.enums = d.enums or {}
  return d
end

local cache = {}

--- proto.load_descriptors(path) -> descriptors | nil, message (cached per path)
function proto.load_descriptors(path)
  if cache[path] then
    return cache[path]
  end
  local f, err = io.open(path, "rb")
  if not f then
    return nil,
      "cannot read the gRPC descriptors "
        .. path
        .. " ("
        .. tostring(err)
        .. "); run verify/dl models sync, which copies the package's src/descriptors.ts"
  end
  local text = f:read("*a")
  f:close()
  local d, perr = proto.parse_descriptors(text, path)
  if not d then
    return nil, perr
  end
  cache[path] = d
  return d
end

local function dir_of(path)
  return string.match(path or "", "^(.*)/[^/]*$") or "."
end

local function method_path(uri)
  return (string.match(uri or "", "^[^?#]*"))
end

-- every message and enum reachable from the methods: the descriptors one client needs
local function subset(d, paths)
  local out = { messages = {}, enums = {}, methods = {} }
  local problems = {}
  local queue = {}
  local function want(name)
    if out.messages[name] == nil and not string.find(name, "^google%.protobuf%.") then
      if d.messages[name] == nil then
        problems[#problems + 1] = "message " .. name .. " is not in the descriptors"
        out.messages[name] = false
      else
        out.messages[name] = d.messages[name]
        queue[#queue + 1] = name
      end
    end
  end
  local function want_enum(name)
    if out.enums[name] == nil then
      if d.enums[name] == nil then
        problems[#problems + 1] = "enum " .. name .. " is not in the descriptors"
        out.enums[name] = false
      else
        out.enums[name] = d.enums[name]
      end
    end
  end
  for _, path in ipairs(paths) do
    local m = d.methods[path]
    out.methods[path] = m
    want(m[1])
    want(m[2])
  end
  local i = 1
  while i <= #queue do
    for _, f in ipairs(d.messages[queue[i]]) do
      local kind, ref = f[3], f[4]
      if kind == "message" and type(ref) == "string" then
        want(ref)
      elseif kind == "enum" and type(ref) == "string" then
        want_enum(ref)
      elseif kind == "map" and type(ref) == "table" then
        if ref[2] == "message" and type(ref[3]) == "string" then
          want(ref[3])
        elseif ref[2] == "enum" and type(ref[3]) == "string" then
          want_enum(ref[3])
        end
      end
    end
    i = i + 1
  end
  for k, v in pairs(out.messages) do
    if v == false then
      out.messages[k] = nil
    end
  end
  for k, v in pairs(out.enums) do
    if v == false then
      out.enums[k] = nil
    end
  end
  return out, problems
end

--- proto.prepare_model(m, spec): the provider's error matchers trait read as
-- com.distilled.openapi#errorMatchers (Distilled's SdkSpec.errorMatchersTrait)
function proto.prepare_model(m, spec)
  local trait = spec.proto and spec.proto.error_matchers_trait
  if not trait then
    return
  end
  for _, shape in pairs(m.shapes) do
    local traits = shape.traits
    if traits and traits[trait] ~= nil and traits["com.distilled.openapi#errorMatchers"] == nil then
      traits["com.distilled.openapi#errorMatchers"] = traits[trait]
    end
  end
end

local function has_trait(op, id)
  return op.def.traits ~= nil and op.def.traits[id] ~= nil
end

--- proto.streaming(ctx, op, unsupported, err) -> unsupported, err
-- gRPC server-streaming operations are callable on the grpc wires: the call collects the
-- stream from one HTTP response ({ items }). Client streaming stays unsupported.
function proto.streaming(ctx, op, unsupported, err)
  local r = ctx.provider.proto
  if
    r
    and r.wire ~= "connect"
    and has_trait(op, "com.distilled.grpc#serverStreaming")
    and not has_trait(op, "com.distilled.grpc#clientStreaming")
  then
    return nil, nil
  end
  return unsupported, err
end

--- proto.plan(plan) -> true | nil, message: loads the descriptors, checks every
-- operation has its method, and keeps the subset this client needs (plan.proto)
function proto.plan(plan)
  local spec = plan.provider
  local r = spec.proto
  local eff = proto.effective(spec)
  plan.proto = { effective = eff }
  if r.wire == "connect" then
    return true
  end
  local path = r.descriptors
  if string.sub(path, 1, 1) ~= "/" then
    path = dir_of(plan.model.path) .. "/" .. path
  end
  local d, err = proto.load_descriptors(path)
  if not d then
    return nil, err
  end
  local problems, paths = {}, {}
  for _, op in ipairs(plan.ops) do
    local mp = method_path(op.http.uri)
    local m = d.methods[mp]
    if not m then
      problems[#problems + 1] = op.id .. ": no gRPC method " .. mp .. " in " .. path
    else
      local stream = m[3] == 1
      local declared = has_trait(op, "com.distilled.grpc#serverStreaming")
      if stream ~= declared then
        problems[#problems + 1] = op.id
          .. ": the descriptors say "
          .. mp
          .. (stream and " streams" or " does not stream")
          .. ", the model says otherwise"
      end
      paths[#paths + 1] = mp
    end
  end
  table.sort(paths)
  local sub, sproblems = subset(d, paths)
  for _, s in ipairs(sproblems) do
    problems[#problems + 1] = path .. ": " .. s
  end
  if #problems > 0 then
    table.sort(problems)
    return nil, compat.concat(problems, "\n")
  end
  plan.proto.descriptors = sub
  plan.proto.source = string.match(path, "([^/]+)$")
  return true
end

---------------------------------------------------------------------------------------
-- emitted files
---------------------------------------------------------------------------------------

-- a descriptor table as emitter values: field arrays as sequences, maps sorted
local function as_value(v)
  if type(v) ~= "table" then
    return v
  end
  if json.is_array(v) or (#v > 0) then
    local items = {}
    for i = 1, #v do
      items[i] = as_value(v[i])
    end
    return emit.list(items)
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = as_value(x)
  end
  return out
end

--- proto.descriptors_file(plan, header) -> descriptors.lua source
function proto.descriptors_file(plan, header)
  local d = plan.proto.descriptors
  local b = emit.buffer()
  b:lines_of(header)
  b:line("--")
  b:lines_of(
    emit.comment(
      "Field numbers, kinds, enums and gRPC methods for the binary wire codec "
        .. "(distilled.protobuf), from Distilled's "
        .. tostring(plan.proto.source)
        .. ": only what this client's operations reach."
    )
  )
  b:line("return {")
  for _, key in ipairs({ "messages", "enums", "methods" }) do
    local entries = {}
    for name, v in pairs(d[key]) do
      entries[name] = as_value(v)
    end
    if next(entries) == nil then
      b:line("  " .. key .. " = {},")
    else
      b:line("  " .. key .. " = {")
      for _, name in ipairs(sorted_keys(entries)) do
        b:lines_of(emit.value(entries[name], "    ", emit.key(name), ","))
      end
      b:line("  },")
    end
  end
  b:line("}")
  return b:text()
end

--- proto.client(plan, header) -> init.lua source
function proto.client(plan, header)
  local spec = plan.provider
  local r = spec.proto
  local eff = plan.proto.effective
  local b = emit.buffer()
  b:lines_of(header)
  b:line("--")
  b:lines_of(emit.comment("local " .. spec.title .. ' = require("' .. spec.name .. '")'))
  b:lines_of(emit.comment("local client = " .. spec.title .. ".new({ transport = ... })"))
  b:lines_of(emit.comment("See README.md next to this file for the options and operations."))
  b:line('local Client = require("distilled.client")')
  local module = r.wire == "connect" and "connect" or "grpc"
  b:line("local " .. module .. ' = require("distilled.protocol.' .. module .. '")')
  b:line('local rpc = require("distilled.protocol.rpc")')
  b:blank()
  b:lines_of(
    emit.comment(
      "The module's own name, so the client loads under whatever directory it was vendored as."
    )
  )
  b:line("local MODULE = ... or " .. emit.string(spec.name))
  b:line('local service = require(MODULE .. ".service")')
  b:blank()
  b:lines_of(
    emit.comment(
      "The client's options (provider spec proto.options): environment variables in order, "
        .. "then the default, whose {name}s are other options."
    )
  )
  b:lines_of(emit.assign("local settings", eff.settings))
  b:blank()
  b:line("local protocol = " .. module .. ".new({")
  if module == "grpc" then
    b:line('  descriptors = require(MODULE .. ".descriptors"),')
    if r.wire == "grpc-web" then
      b:line("  web = true,")
    end
    if r.http2 == true then
      b:line("  http2 = true,")
    elseif type(r.http2) == "string" then
      b:line("  http2 = rpc.when_set(" .. emit.string(r.http2) .. "),")
    end
  end
  local prepare_opts = eff.require_one_of and { require_one_of = emit.list(eff.require_one_of) }
  if prepare_opts then
    b:lines_of(
      emit.value(
        emit.call("rpc.prepare", emit.raw("settings"), prepare_opts),
        "  ",
        "prepare = ",
        ","
      )
    )
  else
    b:line("  prepare = rpc.prepare(settings),")
  end
  b:lines_of(
    emit.value(emit.call("rpc.base_url", as_value(eff.base_url)), "  ", "base_url = ", ",")
  )
  -- header rules: { header, template, unless = name }
  local rules = {}
  for _, rule in ipairs(eff.headers) do
    local text = "{ " .. emit.string(rule[1]) .. ", " .. emit.string(rule[2])
    if rule.unless then
      text = text .. ", unless = " .. emit.string(rule.unless)
    end
    rules[#rules + 1] = emit.raw(text .. " }")
  end
  b:lines_of(emit.value(emit.call("rpc.headers", emit.list(rules)), "  ", "headers = ", ","))
  if r.error_envelope then
    b:lines_of(
      emit.value(
        emit.call("rpc.envelope", as_value(r.error_envelope)),
        "  ",
        "error_envelope = ",
        ","
      )
    )
  end
  if r.unknown_fields then
    b:lines_of(
      emit.value(
        emit.call("rpc.unknown_error", spec.unknown_tag, r.unknown_fields),
        "  ",
        "unknown_error = ",
        ","
      )
    )
  end
  if module == "connect" then
    b:line("  empty_json_body = " .. tostring(eff.empty_json_body) .. ",")
  end
  b:line("  unknown_tag = " .. emit.string(spec.unknown_tag) .. ",")
  b:line("  parse_tag = " .. emit.string(spec.parse_tag) .. ",")
  b:line("})")
  b:blank()
  b:line("return Client.define({")
  b:line("  service = service,")
  b:line("  protocol = protocol,")
  b:line("  options = rpc.client_options(settings),")
  b:line("})")
  return b:text()
end

local function env_text(o)
  local env = o.env
  if env == nil then
    return ""
  end
  local list = type(env) == "table" and env or { env }
  local items = {}
  for i, e in ipairs(list) do
    items[i] = "`" .. e .. "`"
  end
  return "; or from " .. compat.concat(items, ", then ")
end

--- proto.readme(plan) -> markdown section on the client's options and wire
function proto.readme(plan)
  local spec = plan.provider
  local r = spec.proto
  local eff = plan.proto.effective
  local out = {}
  local function add(s)
    out[#out + 1] = s or ""
  end
  add("## Wire and options")
  add()
  if r.wire == "connect" then
    add("Connect unary calls over JSON (`distilled.protocol.connect`).")
  else
    add(
      (r.wire == "grpc-web" and "gRPC-Web" or "Binary gRPC")
        .. " (`distilled.protocol.grpc`): each operation is one protobuf frame, transcoded with"
    )
    add("`descriptors.lua`. Server-streaming operations return `{ items = { ... } }`, the whole")
    add("stream collected from one response.")
    if r.http2 == true then
      add("Calls go over HTTP/2 (curl `--http2-prior-knowledge` for http://).")
    elseif type(r.http2) == "string" then
      add("Calls go over HTTP/2 when `" .. r.http2 .. "` is set.")
    end
  end
  add()
  add("| Option | Meaning |")
  add("| --- | --- |")
  for _, name in ipairs(sorted_keys(eff.docs)) do
    local o = eff.docs[name]
    local what = o.secret and "secret" or "value"
    if o.required then
      what = "required " .. what
    end
    local default = o.default ~= nil and ("; default `" .. tostring(o.default) .. "`") or ""
    local doc = o.doc and (": " .. o.doc) or ""
    add("| `" .. name .. "` | " .. what .. doc .. default .. env_text(o) .. " |")
  end
  if eff.require_one_of then
    add()
    add("One of " .. compat.concat(eff.require_one_of, ", ") .. " is required.")
  end
  add()
  return compat.concat(out, "\n")
end

--- proto.patch_types(plan, text) -> types.lua with a field per proto option
function proto.patch_types(plan, text)
  local spec = plan.provider
  local prefix = string.match(text, "%-%-%-@class ([%w_.]+)%.Options\n")
  if not prefix then
    return text
  end
  local eff = plan.proto.effective
  local lines = {}
  for _, name in ipairs(sorted_keys(eff.docs)) do
    if name ~= spec.base_url.option and name ~= spec.auth.from then
      local o = eff.docs[name]
      local t = o.secret
          and "string|distilled.Secret|fun(host: table): (string|distilled.Secret|nil, distilled.Error?)"
        or "string|number|boolean"
      local doc = o.doc or (o.required and "Required" or "")
      lines[#lines + 1] = "---@field " .. name .. "? " .. t .. (doc ~= "" and (" " .. doc) or "")
    end
  end
  if #lines == 0 then
    return text
  end
  local marker = "---@class " .. prefix .. ".Options\n"
  local at = string.find(text, marker, 1, true)
  local insert = compat.concat(lines, "\n") .. "\n"
  return string.sub(text, 1, at + #marker - 1) .. insert .. string.sub(text, at + #marker)
end

return proto
