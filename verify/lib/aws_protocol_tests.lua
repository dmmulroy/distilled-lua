-- The official Smithy AWS protocol tests (smithy-aws-protocol-tests 1.75.0, the model
-- Distilled's packages/aws/test/protocol-tests runs), replayed through the Lua AWS
-- runtime. Port of Distilled's protocol-tests.test.ts:
--
--   1. each test service and the shapes it reaches become a one-service model (the
--      service's `rename` applied, Byte/Short as Integer), generated with gen/aws.lua
--      and loaded from memory;
--   2. each httpRequestTests case calls the operation with the case's params through a
--      fake transport and compares the request (method, path, query, headers, body:
--      JSON compared as values, XML canonicalised, form pairs sorted);
--   3. each httpResponseTests case returns the canned response and compares the value
--      decoded, or the typed error and its fields.
--
-- Skipped, as in Distilled: server-only cases, cases tagged `defaults` (the client fills
-- in no @default values), rpcv2Cbor, and request cases of operations with an @endpoint
-- host prefix (the runner uses a custom endpoint, which gets no prefix).
--
--   local runner = require("verify.lib.aws_protocol_tests")
--   local results = runner.run{ path = "spec/fixtures/aws/protocol-tests.json",
--                               services = { ... } | nil, filter = "pattern" | nil }
--   -- results = { passed, failed, skipped, failures = { { id, message } }, by_service }
--
-- Run directly: lua verify/lib/aws_protocol_tests.lua [service-pattern] [case-pattern]
local json = require("distilled.json")
local secret = require("distilled.secret")
local codec = require("distilled.aws.codec")
local compat = require("distilled.compat")

local M = {}

M.SERVICES = {
  "aws.protocoltests.json10#JsonRpc10",
  "aws.protocoltests.json10#QueryCompatibleJsonRpc10",
  "aws.protocoltests.json#JsonProtocol",
  "aws.protocoltests.query#AwsQuery",
  "aws.protocoltests.ec2#AwsEc2",
  "aws.protocoltests.restjson#RestJson",
  "aws.protocoltests.restxml#RestXml",
  "aws.protocoltests.restxml.xmlns#RestXmlWithNamespace",
}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function local_name(id)
  return string.match(id, "#(.+)$") or id
end

local function lower_first(s)
  return string.lower(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

---------------------------------------------------------------------------------------
-- the one-service model
---------------------------------------------------------------------------------------

local function refs_of(shape)
  local out = {}
  local function add(r)
    if type(r) == "table" and type(r.target) == "string" then
      out[#out + 1] = r.target
    end
  end
  for _, key in ipairs({ "operations", "resources", "errors" }) do
    for _, r in ipairs(shape[key] or {}) do
      add(r)
    end
  end
  for _, r in pairs(shape.members or {}) do
    add(r)
  end
  for _, key in ipairs({ "input", "output", "member", "key", "value" }) do
    add(shape[key])
  end
  -- resource lifecycle operations
  for _, key in ipairs({ "create", "put", "read", "update", "delete", "list" }) do
    add(shape[key])
  end
  for _, r in ipairs(shape.collectionOperations or {}) do
    add(r)
  end
  return out
end

--- M.service_model(all_shapes, service_id) -> model JSON text
function M.service_model(shapes, service_id)
  local seen, order = {}, {}
  local stack = { service_id }
  while #stack > 0 do
    local id = table.remove(stack)
    if not seen[id] and shapes[id] then
      seen[id] = true
      order[#order + 1] = id
      for _, t in ipairs(refs_of(shapes[id])) do
        stack[#stack + 1] = t
      end
    end
  end
  local subset = {}
  for _, id in ipairs(order) do
    subset[id] = shapes[id]
  end
  local text = json.encode(json.object({ smithy = "2.0", shapes = json.object(subset) }))
  for from, to in pairs(shapes[service_id].rename or {}) do
    local ns = string.match(from, "^(.-)#")
    text = string.gsub(
      text,
      '"' .. string.gsub(from, "%p", "%%%0") .. '"',
      '"' .. ns .. "#" .. to .. '"'
    )
  end
  text = string.gsub(text, '"smithy%.api#Byte"', '"smithy.api#Integer"')
  text = string.gsub(text, '"smithy%.api#Short"', '"smithy.api#Integer"')
  return text
end

---------------------------------------------------------------------------------------
-- loading the generated client from memory
---------------------------------------------------------------------------------------

local function load_chunk(text, name)
  local loader = rawget(_G, "loadstring") or load
  local fn, err = loader(text, "=" .. name)
  if not fn then
    error(name .. ": " .. tostring(err))
  end
  return fn
end

--- M.load_service(text, name) -> class, model, files
function M.load_service(text, name)
  local gen = require("distilled.gen")
  local m, merr = gen.model.from_text(text, name .. ".json")
  if not m then
    error("model " .. name .. ": " .. tostring(merr))
  end
  local files, err = gen.generate({
    model = m,
    provider = {
      name = "pt_" .. string.lower(name),
      title = name,
      base_url = "https://example.com",
      unknown_tag = "UnknownAwsError",
      parse_tag = "ParseError",
      naming = { members = "wire" },
      allow_unsupported = { "streaming" },
    },
    telemetry = false,
  })
  if not files then
    error("generate " .. name .. ": " .. tostring(err))
  end
  local module = "pt_" .. string.lower(name)
  package.loaded[module .. ".service"] =
    load_chunk(files["service.lua"], module .. ".service")(module .. ".service")
  if files["endpoints.lua"] then
    package.loaded[module .. ".endpoints"] =
      load_chunk(files["endpoints.lua"], module .. ".endpoints")(module .. ".endpoints")
  end
  local class = load_chunk(files["init.lua"], module)(module)
  return class, m, files
end

---------------------------------------------------------------------------------------
-- values
---------------------------------------------------------------------------------------

local PRELUDE = {
  String = "string",
  Blob = "blob",
  Boolean = "boolean",
  PrimitiveBoolean = "boolean",
  Integer = "integer",
  PrimitiveInteger = "integer",
  Long = "long",
  PrimitiveLong = "long",
  Float = "float",
  PrimitiveFloat = "float",
  Double = "double",
  PrimitiveDouble = "double",
  BigInteger = "bigInteger",
  BigDecimal = "bigDecimal",
  Timestamp = "timestamp",
  Document = "document",
  Unit = "structure",
}

local function type_of(shapes, target)
  local s = shapes[target]
  if s then
    return s
  end
  return { type = PRELUDE[local_name(target)] or "document" }
end

local NON_FINITE = { NaN = 0 / 0, Infinity = 1 / 0, ["-Infinity"] = -1 / 0 }

-- toRuntime: a case's params as a Lua caller passes / gets them (explicit stack depth
-- bound: the values are shallow)
local function to_runtime(shapes, target, value, depth)
  depth = depth or 0
  if value == nil or value == json.null or depth > 40 then
    return value
  end
  local shape = type_of(shapes, target)
  local t = shape.type
  if t == "timestamp" then
    if type(value) == "number" then
      return value
    end
    return codec.parse_date(value) or value
  elseif t == "float" or t == "double" then
    if type(value) == "string" then
      return NON_FINITE[value] or tonumber(value)
    end
    return value
  elseif t == "list" or t == "set" then
    local out = {}
    for i = 1, #value do
      local v = value[i]
      if v == json.null then
        out[i] = json.null
      else
        out[i] = to_runtime(shapes, shape.member.target, v, depth + 1)
      end
    end
    return json.array(out)
  elseif t == "map" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = v == json.null and json.null or to_runtime(shapes, shape.value.target, v, depth + 1)
    end
    return json.object(out)
  elseif t == "structure" or t == "union" then
    local out = {}
    for k, v in pairs(value) do
      if v ~= json.null then
        local mem = shape.members and shape.members[k]
        out[k] = mem and to_runtime(shapes, mem.target, v, depth + 1) or v
      end
    end
    return json.object(out)
  end
  return value
end
M.to_runtime = to_runtime

-- placeholder: required input members filled in, for response cases
local function placeholder(shapes, target, depth)
  depth = depth or 0
  local shape = type_of(shapes, target)
  local t = shape.type
  if depth > 20 then
    return nil
  end
  if t == "string" then
    return "a"
  elseif t == "enum" or t == "intEnum" then
    for _, mem in pairs(shape.members or {}) do
      return mem.traits and mem.traits["smithy.api#enumValue"] or (t == "enum" and "a" or 0)
    end
    return t == "enum" and "a" or 0
  elseif t == "boolean" then
    return false
  elseif t == "timestamp" then
    return 0
  elseif t == "blob" then
    return ""
  elseif t == "list" or t == "set" then
    return json.array({})
  elseif t == "map" or t == "document" then
    return json.object({})
  elseif t == "union" then
    for name, mem in pairs(shape.members or {}) do
      return json.object({ [name] = placeholder(shapes, mem.target, depth + 1) })
    end
  elseif t == "structure" then
    local out = {}
    for name, mem in pairs(shape.members or {}) do
      if mem.traits and mem.traits["smithy.api#required"] ~= nil then
        out[name] = placeholder(shapes, mem.target, depth + 1)
      end
    end
    return json.object(out)
  end
  return 0
end

-- canonical text of a value: sorted keys, arrays marked, numbers to 1e-9
local function canonical(v, depth)
  depth = depth or 0
  v = secret.unwrap(v)
  if depth > 60 then
    return "<deep>"
  end
  local t = type(v)
  if v == nil then
    return "nil"
  elseif v == json.null then
    return "null"
  elseif t == "number" then
    if v ~= v then
      return "NaN"
    elseif v == 1 / 0 then
      return "Infinity"
    elseif v == -1 / 0 then
      return "-Infinity"
    end
    return string.format("%.9f", v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    if json.is_array(v) or (#v > 0 and next(v, #v) == nil) then
      local parts = {}
      for i = 1, #v do
        parts[i] = canonical(v[i], depth + 1)
      end
      return "[" .. compat.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, x in pairs(v) do
      if x ~= nil then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = tostring(k) .. "=" .. canonical(v[k], depth + 1)
    end
    return "{" .. compat.concat(parts, ",") .. "}"
  end
  return tostring(v)
end
M.canonical = canonical

---------------------------------------------------------------------------------------
-- bodies
---------------------------------------------------------------------------------------

local function decode_entities(text)
  text = string.gsub(text, "&#[xX](%x+);", function(h)
    local n = tonumber(h, 16)
    return n < 128 and string.char(n) or ("&#x" .. h .. ";")
  end)
  text = string.gsub(text, "&#(%d+);", function(d)
    local n = tonumber(d)
    return n < 128 and string.char(n) or ("&#" .. d .. ";")
  end)
  text = string.gsub(text, "&lt;", "<")
  text = string.gsub(text, "&gt;", ">")
  text = string.gsub(text, "&quot;", '"')
  text = string.gsub(text, "&apos;", "'")
  text = string.gsub(text, "&amp;", "&")
  return text
end

--- M.canonical_xml(xml): canonicalXml of protocol-tests.test.ts
--- With `any_order`, same-named siblings are sorted too: a Lua table has no key order,
--- so map entries are serialised in sorted key order, not the case's insertion order.
function M.canonical_xml(xml, any_order)
  xml = string.gsub(xml, "<%?xml[^>]*%?>", "", 1)
  local root = { open = "", name = "", children = {} }
  local stack = { root }
  local pos = 1
  while pos <= #xml do
    local parent = stack[#stack]
    local lt = string.find(xml, "<", pos, true)
    if lt ~= pos then
      local stop = (lt or (#xml + 1)) - 1
      local text = string.sub(xml, pos, stop)
      if string.find(text, "%S") then
        parent.children[#parent.children + 1] = string.format("%q", decode_entities(text))
      end
      pos = stop + 1
    else
      local gt = string.find(xml, ">", pos, true)
      local token = string.sub(xml, pos, gt)
      pos = gt + 1
      if string.sub(token, 1, 2) == "</" then
        stack[#stack] = nil
      else
        local self_closing = string.sub(token, -2) == "/>"
        local inner = string.sub(token, 2, self_closing and -3 or -2)
        inner = string.gsub(string.gsub(inner, "^%s+", ""), "%s+$", "")
        local name = string.match(inner, "^%S+")
        local attrs = {}
        for key, quoted in string.gmatch(string.sub(inner, #name + 1), '([^%s=]+)%s*=%s*("[^"]*")') do
          attrs[#attrs + 1] = key
            .. "="
            .. string.format("%q", decode_entities(string.sub(quoted, 2, -2)))
        end
        for key, quoted in string.gmatch(string.sub(inner, #name + 1), "([^%s=]+)%s*=%s*('[^']*')") do
          attrs[#attrs + 1] = key
            .. "="
            .. string.format("%q", decode_entities(string.sub(quoted, 2, -2)))
        end
        table.sort(attrs)
        local open = "<" .. name .. (#attrs > 0 and (" " .. table.concat(attrs, " ")) or "") .. ">"
        local node = { open = open, name = name, children = {} }
        parent.children[#parent.children + 1] = node
        if not self_closing then
          stack[#stack + 1] = node
        end
      end
    end
  end
  local function print_node(node, depth)
    if type(node) == "string" then
      return node
    end
    local children = {}
    for i, c in ipairs(node.children) do
      children[i] = { c, i }
    end
    table.sort(children, function(a, b)
      local x = type(a[1]) == "string" and "" or a[1].name
      local y = type(b[1]) == "string" and "" or b[1].name
      if x ~= y then
        return x < y
      end
      if any_order then
        local px, py = print_node(a[1], depth + 1), print_node(b[1], depth + 1)
        if px ~= py then
          return px < py
        end
      end
      return a[2] < b[2]
    end)
    local parts = {}
    for i, c in ipairs(children) do
      parts[i] = print_node(c[1], depth + 1)
    end
    return node.open
      .. table.concat(parts)
      .. (node.name == "" and "" or ("</" .. node.name .. ">"))
  end
  return print_node(root, 0)
end

local function url_decode(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function form_pairs(body)
  local out = {}
  for pair in string.gmatch(body, "[^&]+") do
    out[#out + 1] = url_decode(pair)
  end
  table.sort(out)
  return table.concat(out, "\n")
end

local function pct_decode(s)
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function decode_pair(pair)
  local at = string.find(pair, "=", 1, true)
  local k, v
  if at then
    k, v = string.sub(pair, 1, at - 1), string.sub(pair, at + 1)
  else
    k, v = pair, ""
  end
  return pct_decode(k) .. "=" .. pct_decode(v)
end

local function body_matches(actual, expected, media_type, has_map)
  actual = actual or ""
  if media_type == "application/json" and expected ~= "" then
    local a = actual == "" and "" or json.decode(actual)
    local e = json.decode(expected)
    return canonical(a) == canonical(e), canonical(a), canonical(e)
  elseif media_type == "application/xml" and expected ~= "" then
    local a, e = M.canonical_xml(actual), M.canonical_xml(expected)
    if a ~= e and has_map then
      return M.canonical_xml(actual, true) == M.canonical_xml(expected, true), a, e
    end
    return a == e, a, e
  elseif media_type == "application/x-www-form-urlencoded" then
    local a, e = form_pairs(actual), form_pairs(expected)
    return a == e, a, e
  end
  return actual == expected, actual, expected
end

---------------------------------------------------------------------------------------
-- running
---------------------------------------------------------------------------------------

local function header_of(headers, name)
  local lname = string.lower(name)
  for k, v in pairs(headers or {}) do
    if string.lower(k) == lname then
      return v
    end
  end
  return nil
end

local function client_for(class, canned, host, sent)
  local creds = require("distilled.aws.credentials").static({
    access_key_id = "AKIDEXAMPLE",
    secret_access_key = "secret",
    region = "us-west-2",
  })
  return class.new({
    region = "us-west-2",
    credentials = creds,
    endpoint = "https://" .. (host or "example.com"),
    retry = "none",
    random = function()
      return 0
    end,
    epoch = function()
      return 1700000000
    end,
    getenv = function()
      return nil
    end,
    transport = function(req)
      sent[#sent + 1] = req
      local empty = canned.status == 204 or canned.status == 304 or canned.body == nil
      return {
        status = canned.status,
        headers = canned.headers or {},
        body = empty and "" or canned.body,
      }
    end,
  })
end

local function check_request(c, req, has_map)
  local problems = {}
  local function fail(msg)
    problems[#problems + 1] = msg
  end
  local url = req.url
  local raw_path, raw_query = string.match(url, "^%a+://[^/?#]*([^?#]*)%??([^#]*)")
  raw_path = (raw_path == nil or raw_path == "") and "/" or raw_path
  if req.method ~= c.method then
    fail("method " .. tostring(req.method) .. " ~= " .. tostring(c.method))
  end
  if raw_path ~= c.uri then
    fail("path " .. tostring(raw_path) .. " ~= " .. tostring(c.uri))
  end
  local pairs_list, keys = {}, {}
  for p in string.gmatch(raw_query or "", "[^&]+") do
    local d = decode_pair(p)
    pairs_list[#pairs_list + 1] = d
    keys[string.sub(d, 1, (string.find(d, "=", 1, true) or 0) - 1)] = true
  end
  local have = {}
  for _, p in ipairs(pairs_list) do
    have[p] = (have[p] or 0) + 1
  end
  for _, p in ipairs(c.queryParams or {}) do
    local d = decode_pair(p)
    if not have[d] then
      fail("query lacks " .. d .. " (have " .. table.concat(pairs_list, "&") .. ")")
    end
  end
  for _, k in ipairs(c.forbidQueryParams or {}) do
    if keys[k] then
      fail("query has forbidden " .. k)
    end
  end
  for _, k in ipairs(c.requireQueryParams or {}) do
    if not keys[k] then
      fail("query lacks required " .. k)
    end
  end
  local body = req.body or ""
  local headers = {}
  for k, v in pairs(req.headers or {}) do
    headers[string.lower(k)] = v
  end
  if type(req.body) == "string" and headers["content-length"] == nil then
    headers["content-length"] = tostring(#req.body)
  end
  for k, v in pairs(c.headers or {}) do
    local got = header_of(headers, k)
    if got ~= v then
      fail("header " .. k .. " = " .. tostring(got) .. ", want " .. tostring(v))
    end
  end
  for _, k in ipairs(c.forbidHeaders or {}) do
    if header_of(headers, k) ~= nil then
      fail("forbidden header " .. k)
    end
  end
  for _, k in ipairs(c.requireHeaders or {}) do
    if header_of(headers, k) == nil then
      fail("missing header " .. k)
    end
  end
  if c.resolvedHost ~= nil then
    local h = string.match(url, "^%a+://([^/?#]*)")
    if h ~= c.resolvedHost then
      fail("host " .. tostring(h) .. " ~= " .. c.resolvedHost)
    end
  end
  if c.body ~= nil then
    local ok, a, e = body_matches(body, c.body, c.bodyMediaType, has_map)
    if not ok then
      fail("body\n  got:  " .. tostring(a) .. "\n  want: " .. tostring(e))
    end
  end
  return problems
end

-- whether a shape reaches a map (explicit stack)
local function reaches_map(shapes, id)
  local seen, stack = {}, { id }
  while #stack > 0 do
    local cur = table.remove(stack)
    local shape = shapes[cur]
    if shape and not seen[cur] then
      seen[cur] = true
      if shape.type == "map" then
        return true
      end
      for _, t in ipairs(refs_of(shape)) do
        stack[#stack + 1] = t
      end
    end
  end
  return false
end

--- M.run{ path, services, filter, case } -> results
function M.run(opts)
  opts = opts or {}
  local doc = json.decode(read(opts.path or "spec/fixtures/aws/protocol-tests.json"))
  local shapes = doc.shapes
  local results = { passed = 0, failed = 0, skipped = 0, failures = {}, by_service = {} }
  for _, service_id in ipairs(opts.services or M.SERVICES) do
    if not opts.filter or string.find(service_id, opts.filter) then
      local text = M.service_model(shapes, service_id)
      local sub = json.decode(text).shapes
      local service = sub[service_id]
      local protocol
      for k in pairs(service.traits or {}) do
        if string.find(k, "^aws%.protocols#") and require("distilled.gen.aws").PROTOCOLS[k] then
          protocol = k
        end
      end
      local name = local_name(service_id)
      local stats = { passed = 0, failed = 0, skipped = 0 }
      results.by_service[name] = stats
      local ok_load, class_or_err = compat.pcall(function()
        return (M.load_service(text, name))
      end)
      local function record(id, problems)
        if #problems == 0 then
          stats.passed = stats.passed + 1
          results.passed = results.passed + 1
        else
          stats.failed = stats.failed + 1
          results.failed = results.failed + 1
          results.failures[#results.failures + 1] =
            { id = name .. " " .. id, message = table.concat(problems, "\n") }
        end
      end
      local function applies(c)
        if c.protocol ~= protocol or c.appliesTo == "server" then
          return false
        end
        for _, tag in ipairs(c.tags or {}) do
          if tag == "defaults" then
            return false
          end
        end
        if opts.case and not string.find(c.id, opts.case) then
          return false
        end
        return true
      end
      if not ok_load then
        record("load", { tostring(class_or_err) })
      else
        local class = class_or_err
        local ops = {}
        for id, s in pairs(sub) do
          if s.type == "operation" then
            ops[#ops + 1] = id
          end
        end
        table.sort(ops)
        local method_of = {}
        local naming = require("distilled.gen.naming")
        local entries = {}
        for _, id in ipairs(ops) do
          entries[#entries + 1] = { id = id, name = local_name(id) }
        end
        local names = naming.operation_names(entries, {})
        for _, id in ipairs(ops) do
          method_of[id] = names[id]
        end
        local function invoke(op_id, input, canned, host)
          local sent = {}
          local client = client_for(class, canned, host, sent)
          local method = client[method_of[op_id]]
          if not method then
            return nil,
              { tag = "NoMethod", message = "no method " .. tostring(method_of[op_id]) },
              sent
          end
          local ok, v, e = compat.pcall(method, client, input)
          if not ok then
            return nil, { tag = "Raised", message = tostring(v) }, sent
          end
          return v, e, sent
        end
        for _, op_id in ipairs(ops) do
          local op = sub[op_id]
          local traits = op.traits or {}
          local input_id = op.input and op.input.target or "smithy.api#Unit"
          local output_id = op.output and op.output.target or "smithy.api#Unit"
          local host_prefixed = traits["smithy.api#endpoint"] ~= nil
          for _, c in ipairs(traits["smithy.test#httpRequestTests"] or {}) do
            if applies(c) then
              if host_prefixed then
                stats.skipped = stats.skipped + 1
                results.skipped = results.skipped + 1
              else
                local input = to_runtime(sub, input_id, c.params or json.object({}))
                local _, err, sent = invoke(op_id, input, { status = 200, body = "" }, c.host)
                if #sent == 0 then
                  record(
                    c.id .. " (request)",
                    { "no request sent: " .. tostring(err and err.message) }
                  )
                else
                  record(
                    c.id .. " (request)",
                    check_request(c, sent[1], reaches_map(sub, input_id))
                  )
                end
              end
            end
          end
          for _, c in ipairs(traits["smithy.test#httpResponseTests"] or {}) do
            if applies(c) then
              local value, err = invoke(op_id, placeholder(sub, input_id), {
                status = c.code,
                headers = c.headers,
                body = c.body,
              })
              if value == nil then
                record(c.id .. " (response)", {
                  "failed: " .. tostring(err and err.tag) .. ": " .. tostring(err and err.message),
                })
              else
                local actual = canonical(value)
                local expected = canonical(to_runtime(sub, output_id, c.params or json.object({})))
                record(c.id .. " (response)", actual == expected and {} or {
                  "value\n  got:  " .. actual .. "\n  want: " .. expected,
                })
              end
            end
          end
        end
        -- error cases run against the first operation that can return the error
        for error_id, error_shape in pairs(sub) do
          local cases = error_shape.traits and error_shape.traits["smithy.test#httpResponseTests"]
          if error_shape.type == "structure" and cases then
            local found
            for _, op_id in ipairs(ops) do
              for _, e in ipairs(sub[op_id].errors or {}) do
                found = found or (e.target == error_id and op_id)
              end
              for _, e in ipairs(service.errors or {}) do
                found = found or (e.target == error_id and op_id)
              end
            end
            if found then
              for _, c in ipairs(cases) do
                if applies(c) then
                  local op = sub[found]
                  local _, err = invoke(
                    found,
                    placeholder(sub, op.input and op.input.target or "smithy.api#Unit"),
                    { status = c.code, headers = c.headers, body = c.body }
                  )
                  local problems = {}
                  local want_tag = local_name(error_id)
                  if not err or err.tag ~= want_tag then
                    problems[#problems + 1] = "error tag "
                      .. tostring(err and err.tag)
                      .. " ~= "
                      .. want_tag
                      .. " ("
                      .. tostring(err and err.message)
                      .. ")"
                  else
                    local params = {}
                    for k, v in pairs(c.params or {}) do
                      params[k] = v
                    end
                    if params.Message ~= nil then
                      params.message = params.Message
                      params.Message = nil
                    end
                    local wanted = to_runtime(sub, error_id, json.object(params))
                    local actual = {}
                    for k in pairs(wanted) do
                      actual[k] = err[k]
                    end
                    if canonical(actual) ~= canonical(wanted) then
                      problems[#problems + 1] = "error fields\n  got:  "
                        .. canonical(actual)
                        .. "\n  want: "
                        .. canonical(wanted)
                    end
                  end
                  record(c.id .. " (error)", problems)
                end
              end
            end
          end
        end
      end
    end
  end
  return results
end

if arg and arg[0] and string.find(arg[0], "aws_protocol_tests%.lua$") then
  local results = M.run({ filter = arg[1], case = arg[2] })
  for _, f in ipairs(results.failures) do
    print("FAIL " .. f.id .. "\n  " .. string.gsub(f.message, "\n", "\n  "))
  end
  local names = {}
  for k in pairs(results.by_service) do
    names[#names + 1] = k
  end
  table.sort(names)
  for _, n in ipairs(names) do
    local s = results.by_service[n]
    print(
      string.format("%-28s passed %4d  failed %4d  skipped %3d", n, s.passed, s.failed, s.skipped)
    )
  end
  print(
    string.format(
      "total: passed %d, failed %d, skipped %d",
      results.passed,
      results.failed,
      results.skipped
    )
  )
end

return M
