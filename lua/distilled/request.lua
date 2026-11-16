-- request.build: an operation and an input -> the HTTP request to send. Pure: no
-- network, no clock. Replaces Distilled's `buildRequest` (protocol-http.ts).
--
--   request.build{ op = op, input = t, registry = shapes, base_url = "https://...",
--                  headers = { ... },                   -- applied first (auth etc.)
--                  map_member_header = fn(name, value) -> value,   -- optional
--                  unknown_key_to_wire = fn(key) -> wire,          -- optional
--                  empty_json_body = false,                        -- optional
--                  query_style = "dotted" | "brackets" }           -- optional
--     -> { method, url, headers, body = string | nil } | nil, err (InvalidInput, SdkError)
--
-- What it does, in Distilled's order and with its reasons:
-- 1. Secrets anywhere in the input (and in `headers`) are unwrapped here, at the last
--    moment, on a copy (like secret.unwrap_deep); the caller's tables are not changed.
-- 2. Labels are checked before anything else: `.` and `..` (for a greedy `{name+}`
--    label, any segment) fail with InvalidInput, because the URL parser resolves them
--    and `DELETE /things/..` would go out as `DELETE /`. A missing label also fails
--    (Distilled leaves `{name}` in the path; here there is no type checker to stop it).
-- 3. Labels are percent-encoded like encodeURIComponent; greedy labels per segment.
-- 4. Query: scalars `k=v`, lists repeat the key, nested tables go dotted (`name.exact=v`;
--    sending `[object Object]` used to "succeed" with zero results). `style = "comma"`
--    joins a list into one parameter; `style = "deep"` expands a struct member into
--    `name.key=v` after renaming, skipping nulls. `query_style = "brackets"` spells
--    nested values `a[b]=1` and lists `a[0]=x` (Stripe).
-- 5. Headers: lowercased names, String(value). A value holding CR or LF is refused
--    (InvalidInput), so a member cannot inject a header.
-- 6. Body members go out under their wire names (keys.encode); `string_encoded` members
--    as their string spelling. Input keys the schema does not declare pass through as
--    body fields (generated schemas lag real APIs; dropping them would break callers).
-- 7. A `payload` member is the whole body: JSON, or the string itself when its schema is
--    `blob` or the operation declares `body_media_type`.
-- 8. Body rules: a bodied method other than DELETE sends `{}` when body members are
--    declared but unset (some endpoints reject a missing body); GET and HEAD send a body
--    only when body members carry values (some APIs document GET with a body).
-- 9. content-type is set for JSON and form bodies; a member bound to the content-type
--    header wins (a Kubernetes merge patch is application/merge-patch+json).
-- 10. json.null in the input is sent as null; an absent key is omitted.
-- Multipart bodies are not supported yet: such an operation fails with SdkError.
local schema = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")
local errors = require("distilled.errors")
local keys = require("distilled.keys")
local url = require("distilled.url")
local compat = require("distilled.compat")

local request = {}

local null = json.null
local BODYLESS = { GET = true, HEAD = true }

local function invalid(member, message)
  return errors.new("InvalidInput", { member = member, message = message })
end

local function sdk_error(op, message)
  return errors.new("SdkError", { message = "operation " .. tostring(op.name) .. ": " .. message })
end

-- Distilled's invalidLabel: a value whose segment is "." or ".." would address another
-- resource, percent-encoded or not, so no encoding can carry it.
local function invalid_label(member, text, greedy)
  local bad = false
  if greedy then
    for segment in string.gmatch(text .. "/", "([^/]*)/") do
      if segment == "." or segment == ".." then
        bad = true
        break
      end
    end
  else
    bad = text == "." or text == ".."
  end
  if bad then
    return invalid(
      member,
      "Input member "
        .. member
        .. " cannot be "
        .. string.format("%q", text)
        .. ": as a path label it would address another resource"
    )
  end
  return nil
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do
    list[#list + 1] = k
  end
  table.sort(list, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
      return ta < tb
    end
    return a < b
  end)
  return list
end

-- appendQuery: lists repeat the name, nested tables go dotted, scalars String(v).
-- Explicit stack, pushed in reverse so pairs come out in order. Table keys in sorted
-- order (Lua tables have no insertion order).
local function append_query(q, name, value)
  local stack, n = { { name, value } }, 1
  while n > 0 do
    local item = stack[n]
    stack[n] = nil
    n = n - 1
    local k, v = item[1], item[2]
    if schema.is_array_value(v) then
      for i = #v, 1, -1 do
        n = n + 1
        stack[n] = { k, v[i] }
      end
    elseif schema.is_container(v) then
      local ks = sorted_keys(v)
      for i = #ks, 1, -1 do
        local sub = rawget(v, ks[i])
        if sub ~= nil then
          n = n + 1
          stack[n] = { k .. "." .. tostring(ks[i]), sub }
        end
      end
    elseif v ~= nil then
      q:add(k, url.text(v))
    end
  end
end

-- flattenToFormPairs: nested tables become a[b][c], lists index as a[0] (0-based, as in
-- JavaScript); null and absent entries are dropped. `order` lists the top-level keys.
local function form_pairs(q, obj, order)
  -- items: { "obj", table, prefix, order } | { "pair", key, value }
  local stack, n = { { "obj", obj, nil, order } }, 1
  while n > 0 do
    local item = stack[n]
    stack[n] = nil
    n = n - 1
    if item[1] == "pair" then
      q:add(item[2], item[3])
    else
      local t, prefix = item[2], item[3]
      local ks = item[4] or sorted_keys(t)
      local expanded = {}
      for _, key in ipairs(ks) do
        local value = rawget(t, key)
        if value ~= nil and value ~= null then
          local full = prefix and (prefix .. "[" .. tostring(key) .. "]") or tostring(key)
          if schema.is_array_value(value) then
            for i = 1, #value do
              local entry = value[i]
              if entry ~= nil and entry ~= null then
                local indexed = full .. "[" .. tostring(i - 1) .. "]"
                if schema.is_record_value(entry) then
                  expanded[#expanded + 1] = { "obj", entry, indexed }
                else
                  expanded[#expanded + 1] = { "pair", indexed, url.text(entry) }
                end
              end
            end
          elseif schema.is_container(value) then
            expanded[#expanded + 1] = { "obj", value, full }
          else
            expanded[#expanded + 1] = { "pair", full, url.text(value) }
          end
        end
      end
      for i = #expanded, 1, -1 do
        n = n + 1
        stack[n] = expanded[i]
      end
    end
  end
end

-- A copy of the input with every secret unwrapped, like secret.unwrap_deep, but
-- keeping json.null itself: secret.unwrap_deep copies it into a fresh table, which
-- then encodes as {} (reported in STATUS.md, task 03). Tables reached twice are copied
-- once (so a cycle stays a cycle and json.encode reports it). Explicit stack.
local function unwrap_input(value)
  local seen = {}
  local function copy_of(v)
    if secret.is(v) then
      return secret.unwrap(v), false
    end
    if type(v) ~= "table" or v == null then
      return v, false
    end
    if seen[v] then
      return seen[v], false
    end
    local out = {}
    seen[v] = out
    local mt = getmetatable(v)
    if mt ~= nil then
      setmetatable(out, mt)
    end
    return out, true
  end
  local root, fresh = copy_of(value)
  if not fresh then
    return root
  end
  local work, n = { { value, root } }, 1
  while n > 0 do
    local pair = work[n]
    work[n] = nil
    n = n - 1
    for k, v in pairs(pair[1]) do
      local c, is_new = copy_of(v)
      rawset(pair[2], k, c)
      if is_new then
        n = n + 1
        work[n] = { v, c }
      end
    end
  end
  return root
end

local function check_header_value(member, value)
  if string.find(value, "[\r\n]") then
    return invalid(
      member,
      "Input member " .. member .. " cannot hold a line break: it is sent as a header"
    )
  end
  return nil
end

local function misuse(message)
  compat.raise("request.build: " .. message, 3)
end

--- request.build(args) -> request | nil, err
function request.build(args)
  if type(args) ~= "table" then
    misuse("expected a table of arguments")
  end
  local op = args.op
  if type(op) ~= "table" or type(op.method) ~= "string" or type(op.uri) ~= "string" then
    misuse("op must be an operation descriptor with method and uri")
  end
  local base_url = args.base_url or ""
  if type(base_url) ~= "string" then
    misuse("base_url must be a string")
  end
  local registry = args.registry

  -- the plan (Distilled fails here when the Http trait is missing)
  local node = schema.struct({ name = "Empty", members = {} })
  if op.input ~= nil then
    local resolved, err = schema.resolve(op.input, registry)
    if not resolved then
      return nil, sdk_error(op, err.message)
    end
    node = resolved
  end
  if node.t ~= "struct" then
    return nil, sdk_error(op, "input schema must be a struct, got " .. tostring(node.t))
  end
  if op.content_type == "multipart" then
    return nil, sdk_error(op, "multipart request bodies are not supported by distilled-lua yet")
  end
  local plan = schema.plan(node)

  local input = args.input
  if input == nil then
    input = {}
  elseif type(input) ~= "table" or input == null or json.is_array(input) then
    return nil, invalid(nil, "the input of " .. tostring(op.name) .. " must be a table")
  end
  input = unwrap_input(input)

  -- labels first, before anything else is read
  local uri = op.uri
  for _, m in ipairs(plan.by_bind.label) do
    local value = rawget(input, m.name)
    if value == nil then
      return nil,
        invalid(m.name, "Input member " .. m.name .. " is required: it fills the path " .. op.uri)
    end
    local text = url.text(value)
    local wire = m.wire or m.name
    local greedy = m.greedy == true or string.find(uri, "{" .. wire .. "+}", 1, true) ~= nil
    local refused = invalid_label(m.name, text, greedy)
    if refused then
      return nil, refused
    end
    if greedy then
      uri = url.fill(uri, wire, url.encode_greedy_label(text), true)
    else
      uri = url.fill(uri, wire, url.encode_component(text), false)
    end
  end

  local headers = {}
  for name, value in pairs(args.headers or {}) do
    headers[string.lower(name)] = url.text(secret.unwrap(value))
  end
  local member_content_type
  local map_member_header = args.map_member_header
  local query = url.query()
  local body, body_order, body_keys = {}, {}, 0
  local has_body_members = plan.has_body_members
  local raw_body, raw_member

  for _, m in ipairs(plan.members) do
    local value = rawget(input, m.name)
    local bind = m.bind or "body"
    local wire = m.wire or m.name
    if value ~= nil and bind ~= "label" and bind ~= "status" then
      if bind == "header" then
        local name = string.lower(wire)
        local text = url.text(value)
        if map_member_header then
          text = map_member_header(name, text)
        end
        local refused = check_header_value(m.name, text)
        if refused then
          return nil, refused
        end
        headers[name] = text
        if name == "content-type" then
          member_content_type = text
        end
      elseif bind == "query" then
        if m.style == "comma" and schema.is_list_value(value) then
          local parts = {}
          for i = 1, #value do
            parts[i] = url.text(value[i])
          end
          query:add(wire, compat.concat(parts, ","))
        elseif m.style == "deep" then
          local mapped = keys.encode(m.schema, value, registry)
          if schema.is_container(mapped) then
            local ks = sorted_keys(mapped)
            for _, k in ipairs(ks) do
              local v = rawget(mapped, k)
              if v ~= nil and v ~= null then
                append_query(query, wire .. "." .. tostring(k), v)
              end
            end
          end
        elseif args.query_style == "brackets" then
          form_pairs(query, { [wire] = value }, { wire })
        else
          append_query(query, wire, value)
        end
      elseif bind == "payload" then
        raw_body = keys.encode(m.schema, value, registry)
        raw_member = m
      else
        if body[wire] == nil then
          body_order[#body_order + 1] = wire
        end
        if m.string_encoded then
          body[wire] = keys.string_encode(value)
        else
          body[wire] = keys.encode(m.schema, value, registry)
        end
        body_keys = body_keys + 1
      end
    end
  end

  -- undeclared input keys pass through as body fields
  local unknown_key_to_wire = args.unknown_key_to_wire
  for _, key in ipairs(sorted_keys(input)) do
    if not plan.known[key] then
      if type(key) ~= "string" then
        return nil,
          invalid(
            nil,
            "the input of " .. tostring(op.name) .. " has a non-string key " .. tostring(key)
          )
      end
      local wire = unknown_key_to_wire and unknown_key_to_wire(key) or key
      if body[wire] == nil then
        body_order[#body_order + 1] = wire
      end
      body[wire] = rawget(input, key)
      body_keys = body_keys + 1
      has_body_members = true
    end
  end

  local target = base_url .. uri
  if not query:empty() then
    target = target .. "?" .. query:encode()
  end
  local method = string.upper(op.method)
  local bodied = not BODYLESS[method]
  local out = { method = method, url = target, headers = headers }

  local function encode_json(value)
    local text, err = json.encode(value)
    if not text then
      return nil,
        invalid(
          nil,
          "cannot encode the request body of " .. tostring(op.name) .. ": " .. tostring(err.message)
        )
    end
    return text
  end

  if op.content_type == "form-urlencoded" and bodied then
    local form = url.query()
    if raw_body ~= nil and schema.is_record_value(raw_body) then
      form_pairs(form, raw_body, nil)
    else
      form_pairs(form, body, body_order)
    end
    out.body = form:encode()
    headers["content-type"] = "application/x-www-form-urlencoded"
    return out
  end

  if raw_body ~= nil and bodied then
    local media = member_content_type or op.body_media_type
    local raw_node = schema.resolve(raw_member.schema, registry)
    local is_blob = raw_node ~= nil and raw_node.t == "blob"
    if type(raw_body) == "string" and (is_blob or op.body_media_type ~= nil) then
      out.body = raw_body
      headers["content-type"] = media or "application/octet-stream"
      return out
    end
    local text, err = encode_json(raw_body)
    if not text then
      return nil, err
    end
    out.body = text
    headers["content-type"] = media or "application/json"
    return out
  end

  if
    body_keys > 0
    or ((has_body_members or args.empty_json_body == true) and bodied and method ~= "DELETE")
  then
    local text, err = encode_json(json.object(body))
    if not text then
      return nil, err
    end
    out.body = text
    headers["content-type"] = member_content_type or "application/json"
  end
  return out
end

return request
