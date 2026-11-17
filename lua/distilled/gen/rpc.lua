-- RPC models: operations without smithy.api#http, every call a POST to one path with
-- the operation named by a trait (Tencent Cloud API 3.0: com.tencentcloud#action). The
-- provider spec says so with an `rpc` key:
--
--   rpc = {
--     protocol = "distilled.protocol.tencentcloud", -- module: callable(service, args) ->
--                                                   -- protocol, with .options (client
--                                                   -- options) and .option_docs (README)
--     trait = "com.tencentcloud#action",            -- operation trait copied to op.rpc
--     fields = { "service", "version", "action" },  -- the trait's required string fields
--     method = "POST", uri = "/",                   -- the binding every operation gets
--   }
--
-- Distilled's equivalent is the package's generate.ts `structPipes` (the trait becomes
-- `T.Action({ service, version, action })` on the input) plus its hand-written protocol.
-- Hooks: gen/provider.lua validates the key (rpc.validate), gen/ops.lua asks rpc.http
-- for an operation without an http trait and puts rpc.field into the descriptor, and
-- gen/writer.lua hands init.lua and README.md to rpc.client / rpc.readme. Members bound
-- to headers (Tencent's `region` -> X-TC-Region) keep their binding; everything else is
-- the JSON body.
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local naming = require("distilled.gen.naming")

local rpc = {}

local KEYS = { protocol = true, trait = true, fields = true, method = true, uri = true }

local function is_module(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_.]*$") ~= nil
end

--- rpc.validate(value, p) -> normalized rpc table (problems appended to p)
function rpc.validate(value, p)
  if type(value) ~= "table" then
    p[#p + 1] = "provider spec rpc must be { protocol, trait, fields, method, uri }"
    return nil
  end
  local names = {}
  for k in pairs(value) do
    names[#names + 1] = tostring(k)
  end
  table.sort(names)
  for _, k in ipairs(names) do
    if not KEYS[k] then
      p[#p + 1] = "provider spec rpc: unknown key "
        .. k
        .. " (allowed: fields, method, protocol, trait, uri)"
    end
  end
  if not is_module(value.protocol) then
    p[#p + 1] = "provider spec rpc.protocol must be a module name"
  end
  if type(value.trait) ~= "string" or not string.find(value.trait, "^[%w_.]+#[%w_]+$") then
    p[#p + 1] = "provider spec rpc.trait must be a trait id like com.tencentcloud#action"
  end
  local fields = value.fields or {}
  if type(fields) ~= "table" then
    p[#p + 1] = "provider spec rpc.fields must be a list of names"
    fields = {}
  end
  for i, f in ipairs(fields) do
    if not naming.is_identifier(f) then
      p[#p + 1] = "provider spec rpc.fields[" .. i .. "] must be an identifier"
    end
  end
  local method = value.method or "POST"
  if method ~= "POST" and method ~= "GET" then
    p[#p + 1] = "provider spec rpc.method must be POST or GET"
  end
  local uri = value.uri or "/"
  if type(uri) ~= "string" or string.sub(uri, 1, 1) ~= "/" or string.find(uri, "[{}]") then
    p[#p + 1] = "provider spec rpc.uri must be a path without labels"
  end
  return {
    protocol = value.protocol,
    trait = value.trait,
    fields = fields,
    method = method,
    uri = uri,
  }
end

-- the trait's value as plain data: the required fields plus any other scalar fields
local function action_of(ctx, op)
  local spec = ctx.provider.rpc
  local trait = op.def.traits and op.def.traits[spec.trait]
  if type(trait) ~= "table" then
    return nil, op.id .. ": neither smithy.api#http nor the rpc trait " .. spec.trait
  end
  local value = {}
  for _, f in ipairs(spec.fields) do
    if type(trait[f]) ~= "string" or trait[f] == "" then
      return nil, op.id .. ": " .. spec.trait .. " needs a string " .. f
    end
    value[f] = trait[f]
  end
  for _, k in ipairs(ctx.model:keys(trait)) do
    local v = trait[k]
    if value[k] == nil and (type(v) == "string" or type(v) == "number" or type(v) == "boolean") then
      value[k] = v
    end
  end
  -- the service host and the action go into a URL host and headers: no odd bytes
  for _, k in ipairs(ctx.model:keys(trait)) do
    if type(value[k]) == "string" and not string.find(value[k], "^[%w._%-]+$") then
      return nil,
        op.id .. ": " .. spec.trait .. " " .. k .. " " .. value[k] .. " is not a plain name"
    end
  end
  return value
end

--- rpc.http(ctx, op) -> the synthesized http binding | nil, message
-- For an operation without smithy.api#http in an rpc model. The trait must be there.
function rpc.http(ctx, op)
  local value, err = action_of(ctx, op)
  if not value then
    return nil, err
  end
  local spec = ctx.provider.rpc
  return { method = spec.method, uri = spec.uri, code = 200 }
end

--- rpc.field(ctx, op) -> the op descriptor's `rpc` value, or nil outside rpc models
function rpc.field(ctx, op)
  if not ctx.provider.rpc then
    return nil
  end
  return (action_of(ctx, op))
end

local function header(plan, what)
  return require("distilled.gen.writer").header(plan, what)
end

local function protocol_module(spec)
  return require(spec.rpc.protocol)
end

--- rpc.client(plan) -> source of init.lua for an rpc model
function rpc.client(plan)
  local spec = plan.provider
  local b = emit.buffer()
  b:lines_of(header(plan, spec.title .. ' client: what require("' .. spec.name .. '") returns.'))
  b:line("--")
  b:lines_of(emit.comment("local " .. spec.title .. ' = require("' .. spec.name .. '")'))
  b:lines_of(emit.comment("local client = " .. spec.title .. ".new({ transport = ... })"))
  b:lines_of(emit.comment("See README.md next to this file for the options and operations."))
  b:line('local Client = require("distilled.client")')
  b:line("local rpc_protocol = require(" .. emit.string(spec.rpc.protocol) .. ")")
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
  b:line("  protocol = rpc_protocol.new(service, {")
  b:line("    unknown_tag = " .. emit.string(spec.unknown_tag) .. ",")
  b:line("    parse_tag = " .. emit.string(spec.parse_tag) .. ",")
  b:line("  }),")
  b:line("  options = rpc_protocol.options,")
  b:line("})")
  return b:text()
end

--- rpc.option_fields(spec) -> types.lua `---@field` lines for the protocol's options
function rpc.option_fields(spec)
  local proto = protocol_module(spec)
  local lines = {}
  for _, row in ipairs(proto.option_docs or {}) do
    local o = (proto.options or {})[row[1]] or {}
    local t = o.secret
        and "string|distilled.Secret|fun(host: table): (string|distilled.Secret|nil, distilled.Error?)"
      or (o.type or "string")
    local doc = string.gsub(string.gsub(row[2], "`", ""), "%s+", " ")
    lines[#lines + 1] = "---@field " .. row[1] .. "? " .. t .. " " .. doc
  end
  return lines
end

local function md_escape(s)
  return (string.gsub(s, "|", "\\|"))
end

--- rpc.readme(plan) -> README.md for an rpc model
function rpc.readme(plan)
  local spec, m = plan.provider, plan.model
  local proto = protocol_module(spec)
  local out = {}
  local function add(s)
    out[#out + 1] = s or ""
  end
  add("# " .. spec.title .. " client (generated)")
  add()
  add("Generated by distilled-lua (generator " .. plan.generator_version .. ") from")
  add("`" .. ((m.path and string.match(m.path, "([^/]+)$")) or "model") .. "` (" .. m.hash .. ")")
  add(
    "with the provider spec `" .. (spec.package or spec.name) .. "`. Do not edit; regenerate with"
  )
  add("`bin/distilled-lua package`. Runtime modules: `bin/distilled-lua vendor --out <dir>`.")
  add()
  add(
    "Protocol: `"
      .. spec.rpc.protocol
      .. "` (every operation is a `"
      .. spec.rpc.method
      .. " "
      .. spec.rpc.uri
      .. "`"
  )
  add("named by its action).")
  add()
  add("## Construct")
  add()
  add("```lua")
  add("local " .. spec.title .. ' = require("' .. spec.name .. '")')
  add("local client = " .. spec.title .. ".new({")
  add('  host = require("distilled.host.popen")(), -- in Rex: require("distilled.host.rex")()')
  add("})")
  add("```")
  add()
  add("| Option | Meaning |")
  add("| --- | --- |")
  for _, row in ipairs(proto.option_docs or {}) do
    add("| `" .. row[1] .. "` | " .. md_escape(row[2]) .. " |")
  end
  add("| `host`, `transport`, `sleep`, ... | the host seams (see distilled's docs/interfaces.md) |")
  add("| `retry`, `deadline_s`, `tracing`, `validation` | the common client options |")
  add()
  add("Every method returns `value` or `nil, err`; `err.tag` is a class of the protocol's")
  add(
    "error table, a built-in tag, `"
      .. spec.unknown_tag
      .. "` (nothing matched) or `"
      .. spec.parse_tag
      .. "` (an unparseable body)."
  )
  add()
  add("## Operations (" .. #plan.ops .. ")")
  add()
  local fields = spec.rpc.fields
  local label = #fields > 0 and compat.concat(fields, " / ") or "action"
  add("| Method | " .. label .. " | Summary |")
  add("| --- | --- | --- |")
  for _, op in ipairs(plan.ops) do
    local summary = naming.summary(op.def.traits and op.def.traits["smithy.api#documentation"])
      or ""
    local action = rpc.field(plan.ctx, op) or {}
    local parts = {}
    for i, f in ipairs(fields) do
      parts[i] = tostring(action[f])
    end
    add(
      "| `"
        .. op.method_name
        .. "` | `"
        .. md_escape(compat.concat(parts, " "))
        .. "` | "
        .. md_escape(summary)
        .. " |"
    )
  end
  add()
  return compat.concat(out, "\n")
end

return rpc
