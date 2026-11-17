-- The GraphQL generator: a Distilled GraphQL model (.generated-graphql/<pkg>.json, what a
-- package's scripts/convert.ts writes) plus a provider spec -> a Lua client directory:
-- init.lua (the module), schema.lua (types, roots, errors and telemetry as data),
-- types.lua (LuaLS) and README.md.
--
-- Port of Distilled's packages/dev/src/codegen/graphql-client.ts (generateGraphQLClient
-- and validateGraphQLModel) and telemetry.ts (generateGraphQLTelemetry): the same
-- selectable fields, connection detection, field kinds, root helpers, error specs and
-- mutation renames, written as data the runtime (distilled.graphql.sdk) reads.
--
--   local files, err, plan = gen_graphql.generate{ model = <path>, provider = <spec|path>,
--                                                  telemetry = true }
--   gen_graphql.write(files, out_dir)
--
-- The provider spec (providers/<lua>.lua) holds the GraphQL part under `graphql`:
--   return {
--     name = "linear", title = "Linear",
--     graphql = {
--       sdk = "Linear",                                -- the TS sdkName (class name)
--       module = "linear",                             -- default: name
--       url = { option = "base_url", env = "LINEAR_API_URL",
--               default = "https://api.linear.app", path = "/graphql", strip = nil }
--             or "https://api.fly.io/graphql",
--       accept = "application/json",
--       auth = { { option = "api_key", env = { "LINEAR_API_KEY" }, header = "Authorization",
--                  prefix = "Bearer ", trim = true, skip_empty = true }, ... },
--       missing = "LINEAR_API_KEY ... is required",
--       user_agent = { env = "GITHUB_USER_AGENT", default = "distilled.cloud-github" },
--       error_type_code = true,                        -- GitHub's top-level `type`
--       http_detail = { "message" },                   -- body fields an HTTP failure names
--       source = "packages/linear/src/graphql-transport.ts, credentials.ts",  -- for docs
--     },
--   }
-- A file holding only the GraphQL section (providers/graphql/<lua>.lua, for packages
-- whose providers/<lua>.lua is the REST spec) is the same table with `name`/`title` and
-- `graphql`.
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local json = require("distilled.json")
local model_mod = require("distilled.gen.model")
local naming = require("distilled.gen.naming")
local ordered = require("distilled.gen.json_ordered")

local M = {}

M.VERSION = "1"

local null = json.null

---------------------------------------------------------------------------------------
-- provider spec
---------------------------------------------------------------------------------------

local function is_ident(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function is_env(s)
  return type(s) == "string" and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function env_list(v)
  if v == nil then
    return {}
  end
  if type(v) == "string" then
    return { v }
  end
  return v
end

local function check_keys(where, t, allowed, problems)
  local list = {}
  for k in pairs(t) do
    list[#list + 1] = tostring(k)
  end
  table.sort(list)
  for _, k in ipairs(list) do
    if not allowed[k] then
      local names = {}
      for n in pairs(allowed) do
        names[#names + 1] = n
      end
      table.sort(names)
      problems[#problems + 1] = where
        .. ": unknown key "
        .. k
        .. " (valid: "
        .. table.concat(names, ", ")
        .. ")"
    end
  end
end

local SPEC_KEYS = { name = true, title = true, graphql = true }
local GQL_KEYS = {
  sdk = true,
  module = true,
  url = true,
  accept = true,
  auth = true,
  missing = true,
  user_agent = true,
  error_type_code = true,
  http_detail = true,
  source = true,
}
local URL_KEYS = { option = true, env = true, default = true, path = true, strip = true }
local AUTH_KEYS = {
  option = true,
  env = true,
  header = true,
  prefix = true,
  trim = true,
  skip_empty = true,
  doc = true,
}

--- M.check_spec(spec) -> spec (normalized) | nil, message
function M.check_spec(spec)
  local p = {}
  if type(spec) ~= "table" then
    return nil, "provider spec: expected a table"
  end
  check_keys("provider spec", spec, SPEC_KEYS, p)
  if not (type(spec.name) == "string" and string.find(spec.name, "^[a-z][a-z0-9_]*$")) then
    p[#p + 1] = "provider spec: name must be a Lua module name (lower case)"
  end
  local g = spec.graphql
  if type(g) ~= "table" then
    p[#p + 1] = "provider spec: graphql must be a table (the GraphQL client's facts)"
    return nil, table.concat(p, "\n")
  end
  check_keys("graphql", g, GQL_KEYS, p)
  if not is_ident(g.sdk) then
    p[#p + 1] = "graphql.sdk must be an identifier (the TypeScript sdkName, e.g. Linear)"
  end
  if
    g.module ~= nil
    and not (type(g.module) == "string" and string.find(g.module, "^[a-z][a-z0-9_.]*$"))
  then
    p[#p + 1] = "graphql.module must be a Lua module name"
  end
  local options = {}
  if type(g.url) == "table" then
    check_keys("graphql.url", g.url, URL_KEYS, p)
    if not is_ident(g.url.option) then
      p[#p + 1] = "graphql.url.option must be an option name"
    else
      options[g.url.option] = "url"
    end
    if type(g.url.default) ~= "string" then
      p[#p + 1] = "graphql.url.default must be a URL"
    end
    if g.url.env ~= nil and not is_env(g.url.env) then
      p[#p + 1] = "graphql.url.env must be an environment variable name"
    end
  elseif type(g.url) ~= "string" then
    p[#p + 1] = "graphql.url must be a URL or { option, env, default, path, strip }"
  end
  if type(g.auth) ~= "table" or #g.auth == 0 then
    p[#p + 1] = "graphql.auth must be a non-empty list of { option, env, header, prefix }"
  else
    for i, a in ipairs(g.auth) do
      local where = "graphql.auth[" .. i .. "]"
      if type(a) ~= "table" then
        p[#p + 1] = where .. " must be a table"
      else
        check_keys(where, a, AUTH_KEYS, p)
        if not is_ident(a.option) then
          p[#p + 1] = where .. ".option must be an option name"
        elseif options[a.option] then
          p[#p + 1] = where .. ".option " .. a.option .. " is used twice"
        else
          options[a.option] = "auth"
        end
        if type(a.header) ~= "string" or not string.find(a.header, "^[%w%-]+$") then
          p[#p + 1] = where .. ".header must be a header name"
        end
        for _, e in ipairs(env_list(a.env)) do
          if not is_env(e) then
            p[#p + 1] = where .. ".env: " .. tostring(e) .. " is not a variable name"
          end
        end
      end
    end
  end
  for _, k in ipairs({ "accept", "missing", "source" }) do
    if g[k] ~= nil and type(g[k]) ~= "string" then
      p[#p + 1] = "graphql." .. k .. " must be a string"
    end
  end
  if g.user_agent ~= nil then
    if type(g.user_agent) ~= "table" or type(g.user_agent.default) ~= "string" then
      p[#p + 1] = "graphql.user_agent must be { env, default }"
    else
      check_keys("graphql.user_agent", g.user_agent, { env = true, default = true }, p)
    end
  end
  if g.http_detail ~= nil and type(g.http_detail) ~= "table" then
    p[#p + 1] = "graphql.http_detail must be a list of body field names"
  end
  local common = {}
  for _, k in ipairs(require("distilled.client").COMMON_OPTIONS) do
    common[k] = true
  end
  for name in pairs(options) do
    if common[name] then
      p[#p + 1] = "graphql: option " .. name .. " is a common client option"
    end
  end
  if #p > 0 then
    return nil, table.concat(p, "\n")
  end
  return {
    name = spec.name,
    title = spec.title or g.sdk,
    module = g.module or spec.name,
    g = g,
  }
end

--- M.load_spec(path) -> spec | nil, message
function M.load_spec(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "cannot read provider spec " .. path .. ": " .. tostring(err)
  end
  local text = f:read("*a")
  f:close()
  local chunk, lerr = compat.load(text, "@" .. path)
  if not chunk then
    return nil, "provider spec " .. path .. ": " .. tostring(lerr)
  end
  local ok, spec = compat.pcall(chunk)
  if not ok then
    return nil, "provider spec " .. path .. " raised: " .. tostring(spec)
  end
  local checked, cerr = M.check_spec(spec)
  if not checked then
    return nil, "provider spec " .. path .. ":\n" .. cerr
  end
  return checked
end

---------------------------------------------------------------------------------------
-- the model (graphql-client.ts GraphQLModel, validateGraphQLModel)
---------------------------------------------------------------------------------------

local function keys_of(doc, t)
  local list = doc.order[t]
  if list then
    return list
  end
  return emit.sorted_keys(t or {})
end

local function peel(ref)
  local text = ref
  local non_null, list = false, false
  if string.sub(text, -1) == "!" then
    non_null = true
    text = string.sub(text, 1, -2)
  end
  if string.sub(text, 1, 1) == "[" and string.sub(text, -1) == "]" then
    list = true
    text = string.sub(text, 2, -2)
    if string.sub(text, -1) == "!" then
      text = string.sub(text, 1, -2)
    end
  end
  return { name = text, list = list, non_null = non_null }
end
M._peel = peel

--- M.load(path) -> model | nil, message
-- model = { path, hash, bytes, value, order, types, ... }
function M.load(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path .. ": " .. tostring(err)
  end
  local text = f:read("*a")
  f:close()
  local ok, value, order = compat.pcall(ordered.decode, text)
  if not ok or value == nil then
    return nil, path .. ": not JSON: " .. tostring(order or value)
  end
  if type(value) ~= "table" or value.version ~= 1 or type(value.types) ~= "table" then
    return nil, path .. ": not a Distilled GraphQL model (version 1 with types)"
  end
  return {
    path = path,
    hash = model_mod.hash(text),
    bytes = #text,
    value = value,
    order = order,
    types = value.types,
    errors = value.errors or {},
    global_errors = value.globalErrors or {},
  }
end

--- M.validate(m) -> true | nil, message (validateGraphQLModel)
function M.validate(m)
  local v = m.value
  local types = m.types
  local function check_type(ref, coordinate)
    local name = string.gsub(ref, "[%[%]!]", "")
    if types[name] == nil then
      error(coordinate .. ": unknown GraphQL type " .. name, 0)
    end
  end
  local function check_error(tag, coordinate)
    if m.errors[tag] == nil then
      error(coordinate .. ": unknown GraphQL error " .. tostring(tag), 0)
    end
  end
  local ok, err = compat.pcall(function()
    for _, k in ipairs({ "queryType", "mutationType", "subscriptionType" }) do
      local name = v[k]
      if name ~= nil and types[name] == nil then
        error("Unknown GraphQL root " .. tostring(name), 0)
      end
    end
    for _, tag in ipairs(m.global_errors) do
      check_error(tag, "globalErrors")
    end
    for _, name in ipairs(keys_of(m, types)) do
      local t = types[name]
      for _, fname in ipairs(keys_of(m, t.fields)) do
        local field = t.fields[fname]
        local coordinate = name .. "." .. fname
        check_type(field.type, coordinate)
        for _, aname in ipairs(keys_of(m, field.args)) do
          local arg = field.args[aname]
          check_type(arg.type, coordinate .. "(" .. aname .. ")")
          if arg.sensitive ~= nil then
            error(coordinate .. "(" .. aname .. "): only output fields can be sensitive", 0)
          end
        end
        for _, tag in ipairs(field.errors or {}) do
          check_error(tag, coordinate)
        end
        if field.sensitive then
          local target = types[peel(field.type).name]
          if not target or target.kind ~= "SCALAR" then
            error(coordinate .. ": only scalar fields can be sensitive", 0)
          end
        end
      end
      for _, fname in ipairs(keys_of(m, t.inputFields)) do
        check_type(t.inputFields[fname].type, name .. "." .. fname)
      end
      for _, member in ipairs(t.possibleTypes or {}) do
        check_type(member, name)
      end
      for _, member in ipairs(t.interfaces or {}) do
        check_type(member, name)
      end
    end
  end)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

---------------------------------------------------------------------------------------
-- the plan: what generateGraphQLClient computes
---------------------------------------------------------------------------------------

M.CATEGORIES = {
  auth = true,
  badRequest = true,
  notFound = true,
  throttling = true,
  quota = true,
  server = true,
  conflict = true,
}

local TELEMETRY_KEYS = {
  system = true,
  prefix = true,
  propagation = true,
  responseHeaders = true,
  fields = true,
  attributes = true,
}

local function fail(message)
  error({ gen_error = message }, 0)
end

-- the text of one block line may not close the long bracket it is written in
local function check_token(tok, where)
  if string.find(tok, "%s") or string.find(tok, "]=]", 1, true) then
    fail(where .. ": " .. tok .. " cannot be written in the schema data")
  end
end

local function build_plan(m, spec, telemetry_on)
  local v = m.value
  local types = m.types
  local skip_roots = {}
  for _, k in ipairs({ "queryType", "mutationType", "subscriptionType" }) do
    if v[k] then
      skip_roots[v[k]] = true
    end
  end
  -- root operation types are not emitted, so a field returning one (GitHub's
  -- Relay-compat `Query.relay: Query!`) cannot be selected; it is left out
  local function selectable(field)
    return not skip_roots[peel(field.type).name]
  end
  local function kind_of(name)
    return types[name] and types[name].kind
  end
  local function object_like(name)
    local k = kind_of(name)
    return k == "OBJECT" or k == "INTERFACE"
  end
  -- Relay `edges { node }` -> the node type name, else nil
  local function connection_node(type_name)
    local t = types[type_name]
    local edges = t and t.fields and t.fields.edges
    if not edges then
      return nil
    end
    local edge = peel(edges.type)
    if not edge.list then
      return nil
    end
    local et = types[edge.name]
    local node = et and et.fields and et.fields.node
    if not node then
      return nil
    end
    local node_name = peel(node.type).name
    local k = kind_of(node_name)
    if k ~= "OBJECT" and k ~= "INTERFACE" and k ~= "UNION" then
      return nil
    end
    return node_name
  end
  local function args_of(field, where)
    local out = {}
    for _, aname in ipairs(keys_of(m, field.args)) do
      local a = field.args[aname]
      check_token(aname, where)
      check_token(a.type, where .. "(" .. aname .. ")")
      out[#out + 1] = { aname, a.type }
    end
    return out
  end

  -- errors (graphql-client.ts "Errors")
  local error_tags = emit.sorted_keys(m.errors)
  local sdk = spec.g.sdk
  local reserved = {}
  for name in pairs(types) do
    reserved[name] = true
  end
  for _, n in ipairs({ sdk, sdk .. "Error", sdk .. "GlobalError" }) do
    reserved[n] = true
  end
  local errors_data = {}
  for _, tag in ipairs(error_tags) do
    if not is_ident(tag) then
      fail("GraphQL error tag " .. tag .. " is not a valid identifier")
    end
    if reserved[tag] then
      fail("GraphQL error " .. tag .. " collides with " .. tag)
    end
    local e = m.errors[tag]
    if e.category ~= nil and not M.CATEGORIES[e.category] then
      fail("GraphQL error " .. tag .. ": unknown category " .. tostring(e.category))
    end
    local matchers = {}
    for i, mt in ipairs(e.matchers or {}) do
      local entry = {}
      for k, x in pairs(mt) do
        if k ~= "code" and k ~= "message" and k ~= "messageIncludes" then
          fail("GraphQL error " .. tag .. ": unknown matcher key " .. tostring(k))
        end
        entry[k] = x
      end
      matchers[i] = entry
    end
    errors_data[tag] = {
      category = e.category,
      retryable = e.retryable == true or nil,
      matchers = emit.list(matchers),
      description = e.description,
    }
  end
  local global_set = {}
  local globals = {}
  for _, tag in ipairs(m.global_errors) do
    if not global_set[tag] then
      global_set[tag] = true
      globals[#globals + 1] = tag
    end
  end
  table.sort(globals)

  -- object, interface and union types
  local objects, unions, enums, inputs = {}, {}, {}, {}
  for _, name in ipairs(keys_of(m, types)) do
    local t = types[name]
    if string.sub(name, 1, 2) ~= "__" and not skip_roots[name] then
      if t.kind == "OBJECT" or t.kind == "INTERFACE" then
        objects[#objects + 1] = name
      elseif t.kind == "ENUM" then
        enums[#enums + 1] = name
      elseif t.kind == "INPUT_OBJECT" then
        inputs[#inputs + 1] = name
      elseif t.kind == "UNION" then
        unions[#unions + 1] = name
      end
    end
  end
  table.sort(objects)
  table.sort(enums)
  table.sort(inputs)
  table.sort(unions)

  -- fieldMeta: kind letter, target
  local function field_meta(fname, field)
    local p = peel(field.type)
    local node = (not p.list) and connection_node(p.name) or nil
    if node then
      return "c", node
    end
    if p.list and object_like(p.name) then
      return "l", p.name
    end
    if object_like(p.name) or kind_of(p.name) == "UNION" then
      return "o", p.name
    end
    return "s", nil
  end

  local object_lines = {}
  local object_fields = {}
  for _, name in ipairs(objects) do
    local t = types[name]
    check_token(name, "type")
    local lines, fields = {}, {}
    for _, fname in ipairs(keys_of(m, t.fields)) do
      local field = t.fields[fname]
      if selectable(field) then
        check_token(fname, name)
        local kind, target = field_meta(fname, field)
        local args = args_of(field, name .. "." .. fname)
        local line = fname .. " " .. kind .. " " .. (target or "-")
        if kind == "s" and field.sensitive then
          line = line .. " sensitive"
        end
        for _, a in ipairs(args) do
          line = line .. " " .. a[1] .. "=" .. a[2]
        end
        lines[#lines + 1] = line
        fields[#fields + 1] =
          { name = fname, field = field, kind = kind, target = target, args = args }
      end
    end
    object_lines[name] = lines
    object_fields[name] = fields
  end

  -- roots (graphql-client.ts rootFn)
  local roots = {}
  local root_lines = { query = {}, mutation = {} }
  local query_names = {}
  local sdk_mod = require("distilled.graphql.sdk")
  local function add_root(kind, fname, field)
    local own = {}
    local seen = {}
    for _, tag in ipairs(field.errors or {}) do
      if not global_set[tag] and not seen[tag] then
        seen[tag] = true
        own[#own + 1] = tag
      end
    end
    table.sort(own)
    local p = peel(field.type)
    local node = (not p.list) and connection_node(p.name) or nil
    local shape, target
    if node then
      shape, target = "connection", node
    elseif object_like(p.name) then
      shape, target = p.list and "list" or "root", p.name
    else
      shape = p.list and "leaf_list" or "leaf"
    end
    local export = fname
    if kind == "mutation" and query_names[fname] then
      export = fname .. "Mutation"
    end
    if sdk_mod.RESERVED[export] then
      fail("root " .. kind .. "." .. fname .. ": the Lua module name " .. export .. " is reserved")
    end
    check_token(fname, kind)
    local args = args_of(field, kind .. "." .. fname)
    local sensitive = field.sensitive and (shape == "leaf" or shape == "leaf_list")
    local line = export
      .. " "
      .. fname
      .. " "
      .. shape
      .. " "
      .. (target or "-")
      .. " "
      .. (#own > 0 and table.concat(own, ",") or "-")
    if sensitive then
      line = line .. " sensitive"
    end
    for _, a in ipairs(args) do
      line = line .. " " .. a[1] .. "=" .. a[2]
    end
    root_lines[kind][#root_lines[kind] + 1] = line
    roots[#roots + 1] = {
      kind = kind,
      export = export,
      field = fname,
      def = field,
      shape = shape,
      target = target,
      args = args,
      own = own,
      sensitive = sensitive,
    }
  end
  local qt = types[v.queryType]
  for _, fname in ipairs(keys_of(m, qt and qt.fields)) do
    local field = qt.fields[fname]
    if selectable(field) then
      query_names[fname] = true
      add_root("query", fname, field)
    end
  end
  if v.mutationType then
    local mt = types[v.mutationType]
    for _, fname in ipairs(keys_of(m, mt and mt.fields)) do
      local field = mt.fields[fname]
      if selectable(field) then
        add_root("mutation", fname, field)
      end
    end
  end

  -- telemetry (telemetry.ts generateGraphQLTelemetry, keys in snake_case)
  local telemetry = nil
  if telemetry_on and v.telemetry ~= nil then
    local t = v.telemetry
    for k in pairs(t) do
      if not TELEMETRY_KEYS[k] then
        fail("GraphQL telemetry: unsupported key " .. tostring(k))
      end
    end
    if t.propagation ~= nil and t.propagation ~= "w3c" then
      fail("GraphQL telemetry: unsupported propagation " .. tostring(t.propagation))
    end
    local headers = nil
    if t.responseHeaders then
      headers = {}
      for i, h in ipairs(t.responseHeaders) do
        headers[i] = { header = h.header, name = h.name, transform = h.transform }
      end
      headers = emit.list(headers)
    end
    local fields = nil
    if t.fields then
      fields = {}
      for coordinate, rules in pairs(t.fields) do
        local per = {}
        for arg, list in pairs(rules) do
          local out = {}
          for i, r in ipairs(list) do
            local rule = {}
            for k, x in pairs(r) do
              rule[k] = x
            end
            out[i] = rule
          end
          per[arg] = emit.list(out)
        end
        fields[coordinate] = per
      end
    end
    telemetry = {
      system = t.system,
      prefix = t.prefix,
      propagate = t.propagation,
      response_headers = headers,
      fields = fields,
      attributes = t.attributes,
    }
  end

  return {
    model = m,
    provider = spec,
    objects = objects,
    unions = unions,
    enums = enums,
    inputs = inputs,
    object_lines = object_lines,
    object_fields = object_fields,
    roots = roots,
    root_lines = root_lines,
    errors = errors_data,
    error_tags = error_tags,
    globals = globals,
    telemetry = telemetry,
    telemetry_on = telemetry_on,
    connection_node = connection_node,
    selectable = selectable,
    object_like = object_like,
    kind_of = kind_of,
  }
end

---------------------------------------------------------------------------------------
-- writers
---------------------------------------------------------------------------------------

local function header(plan, what)
  local m, spec = plan.model, plan.provider
  local source = string.match(m.path, "([^/]+)$") or "model"
  local lines = {
    "-- " .. what,
    "--",
    "-- Generated by distilled-lua (graphql generator " .. M.VERSION .. ") from " .. source,
    "-- (" .. m.hash .. ", " .. m.bytes .. " bytes) with provider spec " .. spec.name .. ".",
    "-- Do not edit: regenerate with bin/distilled-lua generate-graphql.",
    "-- Roots: " .. #plan.roots .. "; object types: " .. #plan.objects .. ".",
  }
  if not plan.telemetry_on then
    lines[#lines + 1] = "-- Telemetry: off (--no-telemetry)."
  end
  return lines
end

-- a block of lines as a long-bracket string field: `key = [=[ ... ]=],`
local function block(b, indent, key, lines)
  if #lines == 0 then
    b:line(indent .. key .. '"",')
    return
  end
  b:line(indent .. key .. "[=[")
  for _, l in ipairs(lines) do
    b:line(l)
  end
  b:line("]=],")
end

local function write_schema(plan)
  local b = emit.buffer()
  b:lines_of(
    header(plan, plan.provider.title .. " GraphQL schema as data (distilled.graphql.sdk).")
  )
  b:line("--")
  b:lines_of(
    emit.comment(
      "Object field lines: <name> <s|o|l|c> <Type|-> [sensitive] [<arg>=<GraphQL type> ...] "
        .. "(s scalar, o object, l list, c Relay connection). Root lines: <export> <field> "
        .. "<root|list|connection|leaf|leaf_list> <Type|-> <field errors|-> [sensitive] [args]. "
        .. "Each block is parsed on first use."
    )
  )
  b:line("return {")
  b:line("  roots = {")
  block(b, "    ", "query = ", plan.root_lines.query)
  block(b, "    ", "mutation = ", plan.root_lines.mutation)
  b:line("  },")
  b:line("  objects = {")
  for _, name in ipairs(plan.objects) do
    block(b, "    ", emit.key(name), plan.object_lines[name])
  end
  b:line("  },")
  local unions = {}
  for i, n in ipairs(plan.unions) do
    unions[i] = n
  end
  b:lines_of(emit.value(emit.list(unions), "  ", "unions = ", ","))
  local errs = {}
  for tag, e in pairs(plan.errors) do
    errs[tag] = { category = e.category, retryable = e.retryable, matchers = e.matchers }
  end
  b:lines_of(emit.value(errs, "  ", "errors = ", ","))
  b:lines_of(emit.value(emit.list(plan.globals), "  ", "global_errors = ", ","))
  if plan.telemetry then
    b:lines_of(emit.value(plan.telemetry, "  ", "telemetry = ", ","))
  end
  b:line("}")
  return b:text()
end

local function options_of(plan)
  local g = plan.provider.g
  local options = {}
  for _, a in ipairs(g.auth) do
    options[a.option] = { secret = true }
  end
  if type(g.url) == "table" then
    options[g.url.option] = { type = "string" }
  end
  return options
end

local function transport_of(plan)
  local g = plan.provider.g
  local auth = {}
  for i, a in ipairs(g.auth) do
    auth[i] = {
      option = a.option,
      env = emit.list(env_list(a.env)),
      header = a.header,
      prefix = a.prefix,
      trim = a.trim,
      skip_empty = a.skip_empty,
    }
  end
  local url = g.url
  if type(url) == "table" then
    url = {
      option = url.option,
      env = url.env,
      default = url.default,
      path = url.path,
      strip = url.strip,
    }
  end
  return {
    name = plan.provider.title,
    url = url,
    accept = g.accept,
    auth = emit.list(auth),
    missing = g.missing,
    user_agent = g.user_agent,
    error_type_code = g.error_type_code,
    http_detail = g.http_detail and emit.list(g.http_detail) or nil,
  }
end

local function write_init(plan)
  local spec = plan.provider
  local b = emit.buffer()
  b:lines_of(
    header(plan, spec.title .. ' GraphQL client: what require("' .. spec.module .. '") returns.')
  )
  b:line("--")
  b:line("-- local " .. spec.g.sdk .. ' = require("' .. spec.module .. '")')
  b:line("-- local client = " .. spec.g.sdk .. ".new({ host = ... })")
  b:line(
    "-- local value, err = client:run({ ... Queries built from "
      .. spec.g.sdk
      .. ".<root>(...) ... })"
  )
  b:line("-- See README.md next to this file.")
  b:line("")
  b:line(
    "-- The module's own name, so the client loads under whatever directory it was vendored as."
  )
  b:line("local MODULE = ... or " .. emit.string(spec.module))
  b:line("")
  local build = {
    name = spec.g.sdk,
    schema = emit.raw('MODULE .. ".schema"'),
    transport = transport_of(plan),
    options = options_of(plan),
  }
  if not plan.telemetry_on then
    build.telemetry = false
  end
  b:lines_of(emit.value(build, "", 'return require("distilled.graphql.sdk").build(', ")"))
  return b:text()
end

---------------------------------------------------------------------------------------
-- types.lua (LuaLS)
---------------------------------------------------------------------------------------

local LUA_KEYWORDS = {}
for w in
  string.gmatch(
    "and break do else elseif end false for function goto if in local nil not or repeat return then true until while",
    "%S+"
  )
do
  LUA_KEYWORDS[w] = true
end

local function field_key(name)
  if LUA_KEYWORDS[name] then
    return '["' .. name .. '"]'
  end
  return name
end

local function one_line(text, max)
  if type(text) ~= "string" then
    return nil
  end
  local s = string.gsub(text, "%s+", " ")
  s = string.gsub(s, "^ ", "")
  s = string.gsub(s, " $", "")
  if max and #s > max then
    -- cut on a UTF-8 boundary
    local cut = max
    while
      cut > 0
      and string.byte(s, cut + 1)
      and string.byte(s, cut + 1) >= 128
      and string.byte(s, cut + 1) < 192
    do
      cut = cut - 1
    end
    s = string.sub(s, 1, cut) .. "..."
  end
  return s
end

local function write_types(plan)
  local spec = plan.provider
  local m = plan.model
  local types = m.types
  local p = spec.module
  local b = emit.buffer()
  b:line("---@meta")
  local h = header(plan, "LuaLS definitions for the " .. spec.title .. " GraphQL client.")
  for i = 2, #h do
    h[i - 1] = h[i]
  end
  h[#h] = nil
  b:line("-- LuaLS definitions for the " .. spec.title .. " GraphQL client.")
  b:lines_of(h)
  b:line("-- Never required at run time; point lua-language-server's workspace.library here.")
  b:line("-- A GraphQL type T is the class " .. p .. ".T: a lazy Query whose fields are Queries.")
  b:line("")
  b:line("---A lazy GraphQL selection (distilled.graphql). Index it for a field; call it with a")
  b:line("---table of arguments; run it with client:run(plan).")
  b:line("---@class distilled.graphql.Query")
  b:line("---@overload fun(args?: table): distilled.graphql.Query")
  b:line("")
  b:line("---@class distilled.Error")
  b:line("---@field tag string")
  b:line("---@field message string")
  b:line("---@field status? number")
  b:line("---@field code? string")
  b:line("---@field path? (string|number)[]")
  b:line("---@field extensions? table")
  b:line("")
  b:line("---JSON null (`distilled.null`): a value that is present and null, unlike nil.")
  b:line("---@class distilled.Null")
  b:line("")
  b:line("---@class distilled.Secret")
  b:line("")
  b:line("---@class distilled.graphql.Iterator<T>")
  b:line("---@field err? distilled.Error")
  b:line(
    "---@field collect fun(self: distilled.graphql.Iterator<T>, limit?: integer): T[]?, distilled.Error?"
  )
  b:line("---@field close fun(self: distilled.graphql.Iterator<T>)")
  b:line("---@operator call: T?")
  b:line("")

  local function named(name)
    local t = types[name]
    if not t then
      return "any"
    end
    if t.kind == "SCALAR" then
      local s = t.scalar or "unknown"
      if s == "string" or s == "number" or s == "boolean" then
        return s
      end
      if s == "string | number" then
        return "string|number"
      end
      return "any"
    end
    return p .. "." .. name
  end
  -- an input type: nullable inputs accept distilled.Null
  local function arg_type(ref)
    local non_null = string.sub(ref, -1) == "!"
    local inner = non_null and string.sub(ref, 1, -2) or ref
    local lua
    if string.sub(inner, 1, 1) == "[" and string.sub(inner, -1) == "]" then
      local item = arg_type(string.sub(inner, 2, -2))
      if string.find(item, "|", 1, true) then
        item = "(" .. item .. ")"
      end
      lua = item .. "[]"
    else
      lua = named(inner)
    end
    if non_null then
      return lua
    end
    return lua .. "|distilled.Null"
  end
  local function args_table(args, defs)
    if #args == 0 then
      return nil
    end
    local parts = {}
    local required = false
    for i, a in ipairs(args) do
      local nn = string.sub(a[2], -1) == "!"
      required = required or nn
      local k = a[1]
      if LUA_KEYWORDS[k] then
        k = '["' .. k .. '"]'
      end
      parts[i] = k .. (nn and "" or "?") .. ": " .. arg_type(a[2])
    end
    return "{ " .. table.concat(parts, ", ") .. " }", required
  end
  local function query_type(kind, target)
    if kind == "s" or target == nil then
      return "distilled.graphql.Query"
    end
    return p .. "." .. target
  end

  -- module, client, options
  b:line("---@class " .. p .. ".__Options")
  for _, a in ipairs(spec.g.auth) do
    local envs = env_list(a.env)
    b:line(
      "---@field "
        .. a.option
        .. "? string|distilled.Secret|fun(host: table): string? "
        .. (#envs > 0 and ("Default: $" .. table.concat(envs, ", $")) or "")
    )
  end
  if type(spec.g.url) == "table" then
    b:line(
      "---@field "
        .. spec.g.url.option
        .. "? string Default: "
        .. (spec.g.url.env and ("$" .. spec.g.url.env .. ", else ") or "")
        .. spec.g.url.default
    )
  end
  b:line("---@field host? table")
  b:line("---@field transport? fun(request: table): table?, distilled.Error?")
  b:line("---@field retry? string|table")
  b:line("---@field deadline_s? number")
  b:line("---@field tracing? string|table")
  b:line("---@field user_agent? string")
  b:line("")
  b:line("---@class " .. p .. ".__Client")
  b:line(
    "---@field run fun(self: " .. p .. ".__Client, plan: any, ...: any): any, distilled.Error?"
  )
  b:line(
    "---@field pages fun(self: "
      .. p
      .. ".__Client, query: distilled.graphql.Query): distilled.graphql.Iterator<any[]>"
  )
  b:line(
    "---@field items fun(self: "
      .. p
      .. ".__Client, query: distilled.graphql.Query): distilled.graphql.Iterator<any>"
  )
  b:line(
    "---@field with fun(self: "
      .. p
      .. ".__Client, options: "
      .. p
      .. ".__Options): "
      .. p
      .. ".__Client"
  )
  b:line("---@field close fun(self: " .. p .. ".__Client): true?, distilled.Error?")
  b:line("")
  b:line("---@class " .. p .. ".__Module")
  b:line("---@field new fun(options?: " .. p .. ".__Options): " .. p .. ".__Client")
  b:line("---@field errors table<string, table> The error classes, by tag")
  for _, r in ipairs(plan.roots) do
    local at = args_table(r.args)
    local result = (r.shape == "leaf" or r.shape == "leaf_list") and "distilled.graphql.Query"
      or (p .. "." .. r.target)
    local _, required = args_table(r.args)
    local sig = at and ("args" .. (required and "" or "?") .. ": " .. at) or ""
    local doc = one_line(r.def.description, 160)
    b:line(
      "---@field "
        .. field_key(r.export)
        .. " fun("
        .. sig
        .. "): "
        .. result
        .. " "
        .. r.kind
        .. (doc and (": " .. doc) or "")
    )
  end
  b:line("")

  for _, name in ipairs(plan.enums) do
    local values = {}
    for i, ev in ipairs(types[name].enumValues or {}) do
      values[i] = '"' .. ev .. '"'
    end
    b:line(
      "---@alias "
        .. p
        .. "."
        .. name
        .. " "
        .. (#values > 0 and table.concat(values, "|") or "string")
    )
  end
  b:line("")
  for _, name in ipairs(plan.inputs) do
    local t = types[name]
    local doc = one_line(t.description, 200)
    if doc then
      b:line("---" .. doc)
    end
    b:line("---@class " .. p .. "." .. name)
    for _, fname in ipairs(keys_of(m, t.inputFields)) do
      local f = t.inputFields[fname]
      local nn = string.sub(f.type, -1) == "!"
      local fdoc = one_line(f.description, 160)
      b:line(
        "---@field "
          .. field_key(fname)
          .. (nn and "" or "?")
          .. " "
          .. arg_type(f.type)
          .. (fdoc and (" " .. fdoc) or "")
      )
    end
    b:line("")
  end
  for _, name in ipairs(plan.unions) do
    b:line("---One of: " .. table.concat(types[name].possibleTypes or {}, ", "))
    b:line("---@class " .. p .. "." .. name .. " : distilled.graphql.Query")
    b:line("---@field __typename distilled.graphql.Query")
    b:line("")
  end
  for _, name in ipairs(plan.objects) do
    local t = types[name]
    local doc = one_line(t.description, 200)
    if doc then
      b:line("---" .. doc)
    end
    b:line("---@class " .. p .. "." .. name .. " : distilled.graphql.Query")
    for _, f in ipairs(plan.object_fields[name]) do
      local parts = {}
      local at = args_table(f.args)
      if at then
        parts[#parts + 1] = "(args: " .. at .. ")"
      end
      if f.kind == "l" then
        parts[#parts + 1] = "(a list)"
      elseif f.kind == "c" then
        parts[#parts + 1] = "(a connection: a list of nodes)"
      end
      if f.field.sensitive then
        parts[#parts + 1] = "(sensitive: read as a distilled.Secret)"
      end
      local fdoc = one_line(f.field.description, 160)
      if fdoc then
        parts[#parts + 1] = fdoc
      end
      b:line(
        "---@field "
          .. field_key(f.name)
          .. " "
          .. query_type(f.kind, f.target)
          .. (#parts > 0 and (" " .. table.concat(parts, " ")) or "")
      )
    end
    b:line("")
  end
  b:line("---@type " .. p .. ".__Module")
  b:line("local M")
  b:line("return M")
  return b:text()
end

---------------------------------------------------------------------------------------
-- README.md
---------------------------------------------------------------------------------------

local function md_cell(s)
  return (string.gsub(s or "", "|", "\\|"))
end

local function write_readme(plan)
  local spec = plan.provider
  local g = spec.g
  local m = plan.model
  local sdk = g.sdk
  local out = {}
  local function add(s)
    out[#out + 1] = s or ""
  end
  local source = string.match(m.path, "([^/]+)$")
  add("# " .. spec.title .. " GraphQL client (generated)")
  add()
  add("Generated by distilled-lua (graphql generator " .. M.VERSION .. ") from")
  add("`" .. source .. "` (" .. m.hash .. ")")
  add("with the provider spec `" .. spec.name .. "`. Do not edit; regenerate with")
  add(
    "`bin/distilled-lua generate-graphql`. Runtime modules: `bin/distilled-lua vendor --out <dir>`."
  )
  add()
  add("A port of Distilled's `" .. sdk .. "` GraphQL SDK (`graphql-client.ts` output). Roots")
  add("are lazy Queries: building one sends nothing; `client:run(plan)` paints every field the")
  add("plan reads onto one document, posts it once, and returns the plan with Queries replaced")
  add("by their values. See `verify/features/graphql.md` in distilled-lua for the whole surface.")
  add()
  add("## Construct")
  add()
  add("```lua")
  add("local " .. sdk .. ' = require("' .. spec.module .. '")')
  add('local gql = require("distilled.graphql")')
  add("local client = " .. sdk .. ".new({")
  for _, a in ipairs(g.auth) do
    local envs = env_list(a.env)
    add(
      "  "
        .. a.option
        .. " = token, -- default: "
        .. (#envs > 0 and ("$" .. table.concat(envs, " or $")) or "none")
    )
    break
  end
  add('  host = require("distilled.host.popen")(), -- in Rex: require("distilled.host.rex")()')
  add("})")
  add("```")
  add()
  add("| Option | Meaning |")
  add("| --- | --- |")
  for _, a in ipairs(g.auth) do
    local envs = env_list(a.env)
    local header_text = "`" .. a.header .. ": " .. (a.prefix or "") .. "<token>`"
    add(
      "| `"
        .. a.option
        .. "` | secret (a string, a secret, or `fn(host) -> value, err`), sent as "
        .. header_text
        .. (#envs > 0 and ("; default from `" .. table.concat(envs, "`, then `") .. "`") or "")
        .. (a.trim and "; trimmed" or "")
        .. (a.skip_empty and ", no header when empty" or "")
        .. " |"
    )
  end
  if #g.auth > 1 then
    add("| | the first of these with a value wins |")
  end
  if type(g.url) == "table" then
    add(
      "| `"
        .. g.url.option
        .. "` | API base URL, default `"
        .. g.url.default
        .. "`"
        .. (g.url.env and (" or `$" .. g.url.env .. "`") or "")
        .. "; the endpoint is the base"
        .. (g.url.strip and (" without a trailing `" .. g.url.strip .. "`") or "")
        .. " + `"
        .. (g.url.path or "")
        .. "` |"
    )
  else
    add("| | the endpoint is fixed: `" .. g.url .. "` |")
  end
  if g.user_agent then
    add(
      "| `user_agent` | default `"
        .. g.user_agent.default
        .. "`"
        .. (g.user_agent.env and (" or `$" .. g.user_agent.env .. "`") or "")
        .. " |"
    )
  end
  add("| `host`, `transport`, `sleep`, ... | the host seams (distilled's docs/interfaces.md) |")
  add("| `retry`, `deadline_s`, `tracing` | the common client options |")
  add()
  if g.missing then
    add("With no credential at all a run fails with `ConfigError`: " .. g.missing .. ".")
    add()
  end
  add("## Run")
  add()
  local q1
  for _, r in ipairs(plan.roots) do
    if r.kind == "query" and r.shape == "connection" and r.args and #r.args > 0 then
      local has_first = false
      for _, a in ipairs(r.args) do
        has_first = has_first or a[1] == "first"
      end
      if has_first then
        q1 = r
        break
      end
    end
  end
  add("```lua")
  if q1 then
    local fields = plan.object_fields[q1.target] or {}
    local scalar
    for _, f in ipairs(fields) do
      if f.kind == "s" and #f.args == 0 then
        scalar = f.name
        if f.name == "id" then
          break
        end
      end
    end
    scalar = scalar or "__typename"
    add("-- a plan: Queries anywhere in a table; one POST for all of them")
    add("local value, err = client:run({")
    add("  items = gql.map(" .. sdk .. "." .. q1.export .. "({ first = 20 }), function(node)")
    add("    return { " .. scalar .. " = node." .. scalar .. " }")
    add("  end),")
    add("})")
    add("if not value then")
    add("  return nil, err -- err.tag: a tag below, GraphQLFailure, UnknownGraphQLError, ...")
    add("end")
    add()
    add("-- every node of a Relay connection, one request per page")
    add("for node in client:items(" .. sdk .. "." .. q1.export .. "({ first = 50 })) do")
    add("  print(node)")
    add("end")
  else
    add(
      "local value, err = client:run("
        .. sdk
        .. "."
        .. (plan.roots[1] and plan.roots[1].export or "root")
        .. "())"
    )
  end
  add("```")
  add()
  add("Combinators: `gql.map(q, fn)`, `gql.filter(q, fn)`, `gql.flat_map(q, fn)`, `gql.of(v)`,")
  add("`gql.fn(build)`. GraphQL names stay as the schema spells them (`issueCreate`,")
  add("`avatarUrl`), in Queries and in the values a run returns. A field that takes arguments")
  add("is called with a table: `account.byId({ accountId = id })`. Sensitive fields come back")
  add("as `distilled.secret` values. Mutations are never retried; queries are retried (at most")
  add("5 times, 200 ms doubling) while every error is retryable.")
  add()
  add("## Errors (" .. #plan.error_tags .. ")")
  add()
  add(
    "Every root can return the global errors plus its own. `"
      .. sdk
      .. ".errors.<Tag>` is the class."
  )
  add()
  add("| Tag | Category | Retryable | Global | Matchers | Meaning |")
  add("| --- | --- | --- | --- | --- | --- |")
  local global_set = {}
  for _, t in ipairs(plan.globals) do
    global_set[t] = true
  end
  for _, tag in ipairs(plan.error_tags) do
    local e = plan.errors[tag]
    local ms = {}
    for _, mt in ipairs(e.matchers.items) do
      local parts = {}
      for _, k in ipairs({ "code", "message", "messageIncludes" }) do
        if mt[k] then
          parts[#parts + 1] = k .. "=" .. mt[k]
        end
      end
      ms[#ms + 1] = "`" .. table.concat(parts, ", ") .. "`"
    end
    add(
      "| `"
        .. tag
        .. "` | "
        .. (e.category or "")
        .. " | "
        .. (e.retryable and "yes" or "no")
        .. " | "
        .. (global_set[tag] and "yes" or "no")
        .. " | "
        .. md_cell(table.concat(ms, " "))
        .. " | "
        .. md_cell(one_line(e.description, 200) or "")
        .. " |"
    )
  end
  add()
  add("Built-in: `UnknownGraphQLError` (no matcher; `err.coordinate`), `GraphQLFailure` (errors")
  add("with different tags: `err.errors`, `err.data`), `GraphQLTransportError` (no GraphQL")
  add("response), `GraphQLPaginationError`, `GqlError` (a plan that cannot be compiled),")
  add("`ConfigError` (no credential, no transport).")
  add()
  local nq, nm = 0, 0
  for _, r in ipairs(plan.roots) do
    if r.kind == "query" then
      nq = nq + 1
    else
      nm = nm + 1
    end
  end
  add("## Roots (" .. #plan.roots .. ": " .. nq .. " queries, " .. nm .. " mutations)")
  add()
  add("| Root | Kind | Returns | Summary |")
  add("| --- | --- | --- | --- |")
  for _, r in ipairs(plan.roots) do
    local returns = r.def.type
    if r.shape == "connection" then
      returns = returns .. " (connection of " .. r.target .. ")"
    end
    add(
      "| `"
        .. r.export
        .. "` | "
        .. r.kind
        .. " | `"
        .. md_cell(returns)
        .. "` | "
        .. md_cell(one_line(r.def.description, 120) or "")
        .. " |"
    )
  end
  return compat.concat(out, "\n") .. "\n"
end

---------------------------------------------------------------------------------------
-- generate / write
---------------------------------------------------------------------------------------

--- M.generate{ model = path | loaded, provider = path | table, telemetry = true }
--   -> files, nil, plan | nil, message
-- files = { order = { names }, [name] = text }
function M.generate(args)
  local m = args.model
  if type(m) == "string" then
    local merr
    m, merr = M.load(m)
    if not m then
      return nil, merr
    end
  end
  local spec = args.provider
  local serr
  if type(spec) == "string" then
    spec, serr = M.load_spec(spec)
  elseif type(spec) == "table" and spec.g == nil then
    spec, serr = M.check_spec(spec)
  end
  if not spec then
    return nil, serr
  end
  local ok, verr = M.validate(m)
  if not ok then
    return nil, verr
  end
  local r = compat.pack(compat.pcall(build_plan, m, spec, args.telemetry ~= false))
  if not r[1] then
    local e = r[2]
    if type(e) == "table" and e.gen_error then
      return nil, e.gen_error
    end
    error(e, 0)
  end
  local plan = r[2]
  local files = { order = { "init.lua", "schema.lua", "types.lua", "README.md" } }
  files["init.lua"] = write_init(plan)
  files["schema.lua"] = write_schema(plan)
  files["types.lua"] = write_types(plan)
  files["README.md"] = write_readme(plan)
  return files, nil, plan
end

--- M.write(files, dir) -> true | nil, message
function M.write(files, dir)
  for _, name in ipairs(files.order) do
    local path = dir .. "/" .. name
    local f, err = io.open(path, "wb")
    if not f then
      return nil, "cannot write " .. path .. ": " .. tostring(err)
    end
    f:write(files[name])
    f:close()
  end
  return true
end

---------------------------------------------------------------------------------------
-- package layout (bin/distilled-lua package)
---------------------------------------------------------------------------------------

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

--- M.find_model(models_dir, pkg) -> <models_dir>/graphql/<pkg>.json when it exists
-- (`verify/dl models sync` puts a package's GraphQL model there, next to its Smithy
-- models)
function M.find_model(models_dir, pkg)
  local path = models_dir .. "/graphql/" .. tostring(pkg) .. ".json"
  if exists(path) then
    return path
  end
  return nil
end

--- M.find_spec(provider_path, lua_name) -> path | nil: the GraphQL provider spec of a
-- package whose REST spec is provider_path: <dir>/graphql/<lua_name>.lua
function M.find_spec(provider_path, lua_name)
  local dir = string.match(provider_path, "^(.*)/[^/]*$") or "."
  local path = dir .. "/graphql/" .. lua_name .. ".lua"
  if exists(path) then
    return path
  end
  return nil
end

--- M.package_into(dir, model_path, spec_path, telemetry) -> true, line | false, line
-- One GraphQL model into dir (created by the caller), with the `package` report line.
function M.package_into(dir, model_path, spec_path, telemetry, pkg)
  local r = compat.pack(compat.pcall(M.generate, {
    model = model_path,
    provider = spec_path,
    telemetry = telemetry,
  }))
  local files, err, plan = r[2], r[3], r[4]
  if not r[1] then
    files, err = nil, "generator raised: " .. tostring(r[2])
  end
  local name = tostring(pkg) .. "/graphql"
  if not files then
    return false, "FAIL " .. name .. ": " .. (string.match(tostring(err), "^([^\n]*)") or "")
  end
  local ok, werr = M.write(files, dir)
  if not ok then
    return false, "FAIL " .. name .. ": " .. werr
  end
  return true,
    string.format("ok   %s: %d roots, %d object types (graphql)", name, #plan.roots, #plan.objects),
    plan
end

M._naming = naming
M._null = null

return M
