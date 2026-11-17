-- Cloudflare conformance cases (task 19): a sample of operations per model, each with a
-- request case, response cases (envelope success, success with Cloudflare's explicit
-- nulls under strict validation, typed / unknown / global envelope errors) and, for
-- paginated operations, a pagination flow. Writes verify/conform/cloudflare/cases.jsonl.
--
--   lua verify/conform/cloudflare/cases.lua [root]
--
-- Then `node --conditions=bun --experimental-transform-types --no-warnings
-- verify/conform/cloudflare/ts.mjs` answers every case with Distilled's TypeScript SDK
-- (ref.jsonl), and spec/cloudflare_conform_spec.lua (compare.lua) checks the Lua side.
local root = arg and arg[1] or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. package.path

local json = require("distilled.json")
local schema = require("distilled.schema")
local lib = require("verify.conform.cloudflare.lib")

local index = require("cloudflare")

-- operations per model in the sample
local PER_MODEL = 5

local lower_first = require("distilled.gen.cloudflare").ts_export_name

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function has_bind(op, registry, bind)
  local node = schema.resolve(op.input, registry)
  for _, m in ipairs(node.members or {}) do
    if (m.bind or "body") == bind then
      return true
    end
    if bind == "deep" and m.style == "deep" then
      return true
    end
  end
  return false
end

-- the sample: special operations first (host, jurisdiction, deep query, headers,
-- payloads), paginated ones of each mode, then one per HTTP method, in name order
local function sample(service)
  local names = sorted_keys(service.ops)
  local chosen, seen = {}, {}
  local function take(name)
    if not seen[name] and #chosen < PER_MODEL then
      seen[name] = true
      chosen[#chosen + 1] = name
    end
  end
  local reg = service.shapes
  local tests = {
    function(op)
      return op.host ~= nil
    end,
    function(op)
      return op.jurisdiction == true
    end,
    function(op)
      return has_bind(op, reg, "deep")
    end,
    function(op)
      return has_bind(op, reg, "header")
    end,
    function(op)
      return has_bind(op, reg, "payload") and op.content_type == nil
    end,
    function(op)
      return op.pagination and op.pagination.mode == "page"
    end,
    function(op)
      return op.pagination and op.pagination.mode == "cursor"
    end,
    function(op)
      return op.pagination and op.pagination.mode == "single"
    end,
  }
  for _, test in ipairs(tests) do
    for _, name in ipairs(names) do
      if test(service.ops[name]) then
        take(name)
        break
      end
    end
  end
  for _, method in ipairs({ "GET", "POST", "PUT", "PATCH", "DELETE" }) do
    for _, name in ipairs(names) do
      if service.ops[name].method == method then
        take(name)
        break
      end
    end
  end
  return chosen
end

local function text_for(matcher)
  if type(matcher) == "string" then
    return matcher
  elseif type(matcher) == "table" and matcher.includes then
    return "conform " .. matcher.includes .. " case"
  end
  return nil
end

-- a reply that the class's first matcher accepts, or nil
local function typed_reply(class)
  local m = class.matchers and class.matchers[1]
  if not m or m.body or m.headers then
    return nil
  end
  local message = "conform typed error"
  if m.message ~= nil then
    message = text_for(m.message)
    if not message then
      return nil
    end
  end
  local entry = { message = message }
  if m.code ~= nil then
    entry.code = m.code
  end
  return {
    status = m.status or 400,
    headers = { ["content-type"] = "application/json" },
    body = json.encode({
      success = false,
      errors = json.array({ entry }),
      messages = json.array({}),
      result = json.null,
    }),
  }
end

local function error_reply(status, code, message, headers)
  local h = { ["content-type"] = "application/json" }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  local entry = { message = message }
  if code ~= nil then
    entry.code = code
  end
  return {
    status = status,
    headers = h,
    body = json.encode({ success = false, errors = json.array({ entry }) }),
  }
end

-- rotating extra failures: global codes, throttling, status classes, non-JSON pages
local EXTRA = {
  function()
    return error_reply(403, 9109, "Invalid access token")
  end,
  function()
    return error_reply(200, 971, "Please wait and consider throttling your request speed", {
      ["retry-after"] = "4",
    })
  end,
  function()
    return error_reply(403, 10000, "Authentication error")
  end,
  function()
    return error_reply(400, 7003, "Could not route to /x")
  end,
  function()
    return error_reply(400, 1000, "Request timeout")
  end,
  function()
    return { status = 502, headers = { ["content-type"] = "text/html" }, body = "<html>bad</html>" }
  end,
  function()
    return { status = 429, headers = { ["retry-after"] = "3" }, body = "slow down" }
  end,
  function()
    return error_reply(409, 424242, "conflict")
  end,
  function()
    return error_reply(403, 10001, "Unable to authenticate request")
  end,
  function()
    return { status = 404, headers = {}, body = "" }
  end,
}

-- set the items path (relative to the output) in a wire payload to `items`
local function with_items(op, registry, payload, items)
  local node = schema.resolve(op.output, registry)
  local path = op.pagination.items or "result"
  local first, rest = string.match(path, "^([^%.]+)%.?(.*)$")
  local plan = schema.plan(node)
  local p = plan.by_bind.payload[1]
  local target, sub
  if p and p.name == first then
    if rest == "" then
      return json.array(items)
    end
    target, sub = payload, rest
  else
    target, sub = payload, path
  end
  if type(target) ~= "table" or json.is_array(target) then
    target = json.object({})
  end
  local cur = target
  local parts = {}
  for seg in string.gmatch(sub, "[^%.]+") do
    parts[#parts + 1] = seg
  end
  for i = 1, #parts - 1 do
    local nxt = rawget(cur, parts[i])
    if type(nxt) ~= "table" or json.is_array(nxt) or nxt == json.null then
      nxt = json.object({})
      cur[parts[i]] = nxt
    end
    cur = nxt
  end
  cur[parts[#parts]] = json.array(items)
  return target
end

local function item_value(op, registry)
  -- one item: the wire value of the items list's item schema
  local node = schema.resolve(op.output, registry)
  local cur = node
  for seg in string.gmatch(op.pagination.items or "result", "[^%.]+") do
    cur = schema.resolve(cur, registry)
    if cur and cur.t == "list" then
      cur = schema.resolve(cur.item, registry)
    end
    local found
    for _, m in ipairs(cur and cur.members or {}) do
      if m.name == seg then
        found = m
      end
    end
    if not found then
      return json.object({})
    end
    cur = found.schema
  end
  local r = schema.resolve(cur, registry)
  if r and r.t == "list" then
    return lib.wire_value(r.item, registry, 1, "item") or "item"
  end
  return lib.wire_value(cur, registry, 1, "item") or "item"
end

local function flow_replies(op, registry)
  local pg = op.pagination
  local body1 = json.decode((lib.success_body(op, registry)))
  local base = body1.result
  local function reply(n_items, info)
    local items = {}
    for i = 1, n_items do
      items[i] = item_value(op, registry)
    end
    local env = {
      success = true,
      errors = json.array({}),
      messages = json.array({}),
      result = with_items(op, registry, base, items),
      result_info = info,
    }
    return {
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = json.encode(env),
    }
  end
  if pg.mode == "page" then
    return {
      reply(2, { page = 1, per_page = 2, count = 2, total_count = 3 }),
      reply(1, { page = 2, per_page = 2, count = 1, total_count = 3 }),
    }
  elseif pg.mode == "cursor" then
    local token = pg.output_token or ""
    local info = {}
    local sub = string.match(token, "^result_info%.(.+)$")
    if sub == "cursors.after" then
      info.cursors = { after = "c2" }
    elseif sub then
      info[sub] = "c2"
    end
    return { reply(1, info), reply(1, { count = 1 }) }
  end
  return { reply(2, { count = 2 }) }
end

local cases = {}
local dictionaries = {}
local function add(c)
  cases[#cases + 1] = c
end

local ops_total = 0
for _, model in ipairs(index.services) do
  local service = require("cloudflare." .. model .. ".service")
  dictionaries[model] = lib.model_rename_table(root, model)
  local registry = service.shapes
  for _, name in ipairs(sample(service)) do
    ops_total = ops_total + 1
    local op = service.ops[name]
    local id = model .. "." .. name
    local input, input_ts = lib.input(op, registry)
    local base = { model = model, op = name, ts = lower_first(op.name) }
    local function case(kind, suffix, fields)
      local c = { id = id .. "#" .. suffix, kind = kind, input = input, input_ts = input_ts }
      for k, v in pairs(base) do
        c[k] = v
      end
      for k, v in pairs(fields or {}) do
        c[k] = v
      end
      add(c)
    end
    case("request", "request")
    if op.jurisdiction then
      case("request", "request-jurisdiction", { jurisdiction = "eu" })
    end
    local binary = false
    local node = schema.resolve(op.output, registry)
    if node and node.t == "struct" then
      for _, m in ipairs(schema.plan(node).by_bind.payload) do
        local r = schema.resolve(m.schema, registry)
        binary = binary or (r and r.t == "blob")
      end
    end
    if not binary then
      local body, headers = lib.success_body(op, registry)
      case(
        "response",
        "success",
        { replies = { { status = 200, headers = headers, body = body } } }
      )
      local nbody, nheaders = lib.success_body(op, registry, { nulls = true })
      case("response", "success-nulls-strict", {
        validation = "strict",
        replies = { { status = 200, headers = nheaders, body = nbody } },
      })
    end
    for _, tag in ipairs(op.errors or {}) do
      local class = service.errors[tag]
      local r = class and typed_reply(class)
      if r then
        case("response", "typed-" .. tag, { replies = { r } })
        break
      end
    end
    case("response", "unknown", { replies = { error_reply(200, 424242, "something new") } })
    case("response", "extra", {
      replies = { EXTRA[(ops_total - 1) % #EXTRA + 1]() },
    })
    if op.pagination then
      local flow_input, flow_ts = lib.input(op, registry)
      local tok = op.pagination.input_token
      if tok then
        flow_input[tok] = nil
        flow_ts[require("distilled.gen.cloudflare").ts_member_name(tok)] = nil
      end
      case("flow", "flow", {
        input = flow_input,
        input_ts = flow_ts,
        replies = flow_replies(op, registry),
        mode = op.pagination.mode,
      })
    end
  end
end

local path = root .. "/verify/conform/cloudflare/cases.jsonl"
local f = assert(io.open(path, "wb"))
for _, c in ipairs(cases) do
  f:write(assert(json.encode(c)), "\n")
end
f:close()
-- the comparison's key-dictionary renames, so it runs without models/ (not committed)
local df = assert(io.open(root .. "/verify/conform/cloudflare/dictionaries.json", "wb"))
df:write(assert(json.encode(dictionaries)), "\n")
df:close()
print(
  string.format(
    "cloudflare conform: %d cases over %d operations of %d models -> %s",
    #cases,
    ops_total,
    #index.services,
    path
  )
)
