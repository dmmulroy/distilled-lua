-- The REST protocol for bearer/header-auth JSON APIs. Port of Distilled's
-- makeRestProtocol (protocol-rest.ts: requestFor, decodeText, decodeSuccess,
-- checkSuccess) on top of the layer-2 algorithms.
--
--   local protocol = rest.new{
--     base_url = fn(creds, { uri, method, server }) | "https://...",
--     headers = fn(creds) -> { authorization = ... },        -- rest.bearer("api_key")
--     error_envelope = fn(body) -> { code, message } | nil,  -- default: code, message | error
--     error_fields_at = "/error",       -- where a typed error's declared fields live
--     status_map = { [404] = class, ... },                    -- default errors.STATUS_MAP
--     classify_error = fn(info) -> err | nil,                 -- consulted first
--     unknown_tag = "UnknownNeonError", parse_tag = "NeonParseError",
--     unknown_error = fn(info) -> err, parse_error = fn(info) -> err,   -- optional
--     transform_response = fn(body) -> body,
--     map_member_header, unknown_key_to_wire, empty_json_body, query_style,  -- request.build
--     user_agent = "...",
--   }
--   protocol.call(ctx, op, input) -> value, nil, meta | nil, err, meta
--   protocol.encode(ctx, op, input [, creds]) -> request | nil, err   (no send)
--   protocol.decode(ctx, op, response) -> value | nil, err
--
-- ctx = { service, credentials = fn() -> creds | nil, err, host, tracer, span,
--         validation = "lenient" | "additional" | "strict", timeout, attempt, user_agent }.
-- meta = { status, headers } whenever a response arrived.
local compat = require("distilled.compat")
local errors = require("distilled.errors")
local json = require("distilled.json")
local keys = require("distilled.keys")
local noop = require("distilled.trace.noop")
local redact = require("distilled.redact")
local request = require("distilled.request")
local retry = require("distilled.retry")
local schema = require("distilled.schema")
local secret = require("distilled.secret")
local validate = require("distilled.validate")

local rest = {}

rest.VERSION = "0.1.0"
rest.USER_AGENT = "distilled-lua/" .. rest.VERSION

local null = json.null

local function trim(s)
  return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- a raise inside a provider callback becomes an SdkError; a raised error table is the
-- error itself (Distilled: a baseUrl that throws fails the call with what it threw)
local function callback_error(what, raised)
  if errors.is(raised) then
    return raised
  end
  local message = type(raised) == "table" and rawget(raised, "message") or raised
  return errors.new(
    "SdkError",
    { message = what .. " raised: " .. tostring(message), cause = raised }
  )
end

-- fn(...) -> its results, or nil, SdkError when it raised
local function protect(what, fn, ...)
  local r = compat.pack(compat.pcall(fn, ...))
  if not r[1] then
    return false, callback_error(what, r[2])
  end
  return true, compat.unpack(r, 2, r.n)
end

--- rest.bearer(option) -> headers function: authorization = "Bearer <creds[option]>"
-- (no header when the option has no value)
function rest.bearer(option)
  return function(creds)
    local v = creds and creds[option]
    if v == nil then
      return {}
    end
    return { authorization = "Bearer " .. tostring(secret.unwrap(v)) }
  end
end

--- rest.header(header_name, option) -> headers function: header_name = creds[option]
function rest.header(header_name, option)
  local name = string.lower(header_name)
  return function(creds)
    local v = creds and creds[option]
    if v == nil then
      return {}
    end
    return { [name] = tostring(secret.unwrap(v)) }
  end
end

-- defaultErrorEnvelope: code (string or number) and message, else a string `error`
local function default_envelope(body)
  if type(body) ~= "table" or body == null or json.is_array(body) then
    return nil
  end
  local code = rawget(body, "code")
  if type(code) ~= "string" and type(code) ~= "number" then
    code = nil
  end
  local message = rawget(body, "message")
  if type(message) ~= "string" then
    message = rawget(body, "error")
    if type(message) ~= "string" then
      message = nil
    end
  end
  return { code = code, message = message }
end
rest.default_error_envelope = default_envelope

local function lower_headers(h)
  if type(h) ~= "table" then
    return {}
  end
  for k in pairs(h) do
    if type(k) == "string" and string.find(k, "%u") then
      local out = {}
      for k2, v in pairs(h) do
        out[type(k2) == "string" and string.lower(k2) or k2] = v
      end
      return out
    end
  end
  return h
end

-- the authority of a URL: host and port (server.address / server.port)
local function host_and_port(target)
  local host = retry.host_of(target)
  local authority = string.match(target, "^%a[%w+.-]*://([^/?#]*)") or ""
  authority = string.gsub(authority, "^.*@", "")
  local port = string.match(authority, ":(%d+)$")
  if port then
    return host, tonumber(port)
  end
  return host, string.find(target, "^https") and 443 or 80
end

-- numbers in response headers: Number(raw) unless blank; text that is not a number is
-- kept as sent, so strict validation reports it (withResponseHeaders)
local function header_value(member, raw, registry)
  local node = schema.resolve(member.schema, registry)
  if node and node.t == "number" and trim(raw) ~= "" then
    local n = retry._js_number(raw)
    if n ~= nil then
      return n
    end
  end
  return raw
end

--- rest.new(opts) -> protocol
function rest.new(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    compat.raise("rest.new: expected an options table", 2)
  end
  local base_url = opts.base_url
  if type(base_url) ~= "string" and type(base_url) ~= "function" then
    compat.raise("rest.new: base_url must be a string or a function(creds, route)", 2)
  end
  if opts.headers ~= nil and type(opts.headers) ~= "function" then
    compat.raise("rest.new: headers must be a function(creds) -> table", 2)
  end
  local envelope = opts.error_envelope or default_envelope
  local status_map = opts.status_map or errors.STATUS_MAP
  local unknown_class = errors.define({ tag = opts.unknown_tag or "UnknownError" })
  local parse_class =
    errors.define({ tag = opts.parse_tag or "ParseError", categories = { "ParseError" } })
  local user_agent = opts.user_agent or rest.USER_AGENT

  local protocol = {
    options = opts,
    unknown_class = unknown_class,
    parse_class = parse_class,
  }

  -- the operation's declared error classes, resolved once per op table (long-lived)
  local class_cache = {}
  local function classes_of(service, op)
    local list = class_cache[op]
    if list then
      return list
    end
    list = {}
    local declared = (service and service.errors) or {}
    for _, name in ipairs(op.errors or {}) do
      local class = declared[name] or errors.classes[name]
      if errors.is_class(class) then
        list[#list + 1] = class
      end
    end
    class_cache[op] = list
    return list
  end

  local function unknown_error(info)
    if opts.unknown_error then
      local ok, err = protect("the protocol's unknown_error", opts.unknown_error, info)
      if not ok then
        return err
      end
      if errors.is(err) then
        return err
      end
    end
    return errors.new(unknown_class, {
      status = info.status,
      code = info.code ~= nil and tostring(info.code) or nil,
      message = info.message,
      body = info.body,
      headers = info.headers,
    })
  end

  local function parse_error(op, info)
    if opts.parse_error then
      local ok, err = protect("the protocol's parse_error", opts.parse_error, info)
      if not ok then
        return err
      end
      if errors.is(err) then
        return err
      end
    end
    local cause = info.cause
    local why = type(cause) == "table" and cause.message or tostring(cause)
    return errors.new(parse_class, {
      message = "cannot decode the response of " .. tostring(op.name) .. ": " .. tostring(why),
      body = info.body,
      cause = cause,
    })
  end

  -----------------------------------------------------------------------------------
  -- request
  -----------------------------------------------------------------------------------

  --- protocol.encode(ctx, op, input [, creds]) -> request | nil, err
  function protocol.encode(ctx, op, input, creds)
    ctx = ctx or {}
    if creds == nil then
      if ctx.credentials then
        local c, err = ctx.credentials()
        if c == nil then
          return nil, err
        end
        creds = c
      else
        creds = {}
      end
    end
    local url = base_url
    if type(base_url) == "function" then
      local ok, v, err = protect(
        "the protocol's base_url",
        base_url,
        creds,
        { uri = op.uri, method = op.method, server = op.server }
      )
      if not ok then
        return nil, v
      end
      if type(v) ~= "string" then
        return nil,
          errors.is(err) and err or errors.new(
            "ConfigError",
            { message = "no base URL for " .. tostring(op.name), key = "base_url" }
          )
      end
      url = v
    end
    local headers
    if opts.headers then
      local ok, h, err = protect("the protocol's headers", opts.headers, creds)
      if not ok then
        return nil, h
      end
      if type(h) ~= "table" then
        return nil,
          errors.is(err) and err or errors.new(
            "SdkError",
            { message = "the protocol's headers returned no table" }
          )
      end
      headers = h
    end
    local service = ctx.service or {}
    return request.build({
      op = op,
      input = input,
      registry = service.shapes,
      base_url = url,
      headers = headers,
      map_member_header = opts.map_member_header,
      unknown_key_to_wire = opts.unknown_key_to_wire,
      empty_json_body = opts.empty_json_body,
      query_style = opts.query_style,
      -- the multipart boundary comes from host.random (deterministic under a test host)
      host = ctx.host,
    })
  end

  -----------------------------------------------------------------------------------
  -- response
  -----------------------------------------------------------------------------------

  -- status >= 400: classify_error, typed matchers, status map, unmapped 5xx, unknown
  local function decode_failure(ctx, op, status, headers, text, value, non_json)
    local env = {}
    if not non_json then
      local ok, e = protect("the protocol's error_envelope", envelope, value)
      if not ok then
        return e
      end
      if type(e) == "table" then
        env = e
      end
    end
    local trimmed = trim(text)
    local message = env.message
    if message == nil then
      message = (non_json and trimmed ~= "") and trimmed or ("HTTP " .. tostring(status))
    end
    local body = non_json and text or value
    local now = ctx.host and ctx.host.epoch and ctx.host.epoch() or os.time()

    -- 0. the provider's own reading
    if opts.classify_error then
      local ok, classified = protect("the protocol's classify_error", opts.classify_error, {
        status = status,
        code = env.code,
        message = message,
        body = body,
        headers = headers,
      })
      if not ok then
        return classified
      end
      if classified ~= nil then
        if errors.is(classified) then
          return classified
        end
        return errors.new(
          "SdkError",
          { message = "classify_error returned a value that is not an error" }
        )
      end
    end

    -- 1. the operation's declared errors; a string envelope code never satisfies a
    -- numeric code matcher, so only number codes take part (Distilled's rule)
    local typed = errors.match(classes_of(ctx.service, op), {
      status = status,
      code = type(env.code) == "number" and env.code or nil,
      message = message,
      body = body,
      headers = headers,
      fields_at = opts.error_fields_at,
      retry_after = retry.parse_server_hint(headers, now),
    })
    if typed then
      if typed.code == nil and env.code ~= nil then
        typed.code = env.code
      end
      return typed
    end

    -- 2. the status map; retry_after only on retryable statuses
    local class = status_map[status]
    if class == nil and status >= 500 then
      -- 3. unmapped 5xx (proxy statuses) is a retryable server error
      class = errors.InternalServerError
    end
    if class then
      return errors.new(class, {
        message = message,
        status = status,
        code = env.code,
        body = body,
        headers = headers,
        retry_after = retry.parse_for_status(status, headers, now),
      })
    end

    -- 4. the provider's fallback; only non-5xx reach it, so it is never retried
    return unknown_error({
      status = status,
      code = env.code,
      message = message,
      body = body,
      headers = headers,
    })
  end

  -- a 2xx body (decodeSuccess + checkSuccess)
  local function decode_success(ctx, op, status, headers, text, value, non_json)
    local service = ctx.service or {}
    local registry = service.shapes
    local output = op.output
    local node
    if output ~= nil then
      local resolved, err = schema.resolve(output, registry)
      if not resolved then
        return nil, errors.new("SdkError", { message = err.message })
      end
      node = resolved
    end
    local body
    if non_json then
      body = text
    elseif value == nil then
      -- an empty body (204, or 200 with nothing): "" for a string output, else {}
      body = (node and node.t == "string") and "" or json.object({})
    else
      body = value
    end
    if opts.transform_response then
      local ok, transformed =
        protect("the protocol's transform_response", opts.transform_response, body)
      if not ok then
        return nil, transformed
      end
      body = transformed
    end

    local mapped = body
    local plan
    if node and node.t == "struct" then
      plan = schema.plan(node)
    end
    local payload = plan and plan.payload
    if payload then
      -- a member that receives the whole body (RawResponse) next to header members
      mapped = json.object({ [payload.name] = keys.decode(payload.schema, body, registry) })
    elseif output ~= nil then
      mapped = keys.decode(output, body, registry)
    end
    if plan and schema.is_record_value(mapped) then
      local copied = false
      local function own()
        if not copied then
          local c = {}
          for k, v in pairs(mapped) do
            c[k] = v
          end
          mapped = setmetatable(c, getmetatable(mapped))
          copied = true
        end
      end
      for _, m in ipairs(plan.by_bind.header or {}) do
        local raw = headers[string.lower(m.wire or m.name)]
        if raw ~= nil then
          own()
          mapped[m.name] = header_value(m, raw, registry)
        end
      end
      for _, m in ipairs(plan.by_bind.status or {}) do
        own()
        mapped[m.name] = status
      end
    end

    if output == nil then
      return mapped
    end
    local sensitive = redact.holds_sensitive(output, registry)
    if non_json and sensitive then
      -- a non-JSON body for an output that can hold a secret fails in every mode
      return nil, parse_error(op, { body = "[REDACTED]", cause = "Invalid JSON response" })
    end
    local mode = ctx.validation or "lenient"
    if mode ~= "lenient" then
      local ok, mismatch = validate.check(output, mapped, registry, { exact = mode == "strict" })
      if not ok then
        if sensitive then
          return nil, parse_error(op, { body = "[REDACTED]", cause = validate.withhold(mismatch) })
        end
        return nil, parse_error(op, { body = non_json and text or value, cause = mismatch })
      end
    end
    if sensitive then
      return redact.wrap(output, mapped, registry)
    end
    return mapped
  end

  --- protocol.decode(ctx, op, response) -> value | nil, err
  function protocol.decode(ctx, op, res)
    ctx = ctx or {}
    local status = res.status
    local headers = res.headers
    local text = res.body or ""
    if type(text) ~= "string" then
      text = tostring(text)
    end
    local service = ctx.service or {}
    if status >= 200 and status < 300 and op.output ~= nil then
      -- binary outputs return the body bytes untouched
      local node = schema.resolve(op.output, service.shapes)
      if node and node.t == "blob" then
        return text
      end
    end
    -- read as text and parse tolerantly: error pages are often not JSON
    local value, non_json = nil, false
    if trim(text) ~= "" then
      local v = json.decode(text)
      if v == nil then
        non_json = true
      else
        value = v
      end
    end
    if status >= 400 then
      return nil, decode_failure(ctx, op, status, headers, text, value, non_json)
    end
    return decode_success(ctx, op, status, headers, text, value, non_json)
  end

  -----------------------------------------------------------------------------------
  -- the whole call
  -----------------------------------------------------------------------------------

  --- protocol.call(ctx, op, input) -> value, nil, meta | nil, err, meta
  function protocol.call(ctx, op, input)
    local tracer = ctx.tracer or noop
    local span = ctx.span or noop.NOOP_SPAN
    local host = ctx.host or {}
    local attempt = ctx.attempt or {}

    local creds, cerr
    if ctx.credentials then
      creds, cerr = tracer:with("distilled.credentials", { debug = true }, function()
        return ctx.credentials()
      end)
      if creds == nil then
        return nil, cerr
      end
    else
      creds = {}
    end

    local req, berr = tracer:with("distilled.request.build", { debug = true }, function()
      return protocol.encode(ctx, op, input, creds)
    end)
    if req == nil then
      return nil, berr
    end

    local h = req.headers
    local traceparent = tracer:traceparent()
    if
      traceparent
      and not (ctx.service and ctx.service.telemetry and ctx.service.telemetry.propagate == false)
    then
      h["traceparent"] = traceparent
    end
    if h["accept"] == nil then
      h["accept"] = "application/json"
    end
    if h["user-agent"] == nil then
      h["user-agent"] = ctx.user_agent or user_agent
    end
    req.timeout = ctx.timeout

    local server, port = host_and_port(req.url)
    span:set("http.request.method", req.method)
    span:set("server.address", server)
    span:set("server.port", port)
    attempt.host = server

    local transport = host.transport
    if transport == nil then
      return nil,
        errors.new("ConfigError", {
          message = "no transport: pass transport = ... (for example "
            .. 'require("distilled.transport.popen_curl")) or a host',
          key = "transport",
        })
    end
    local res, terr = tracer:with("distilled.transport", {
      debug = true,
      attributes = { ["http.request.method"] = req.method, ["server.address"] = server },
    }, function(s)
      local r, e = transport(req)
      if type(r) == "table" then
        s:set("http.response.status_code", r.status)
      end
      return r, e
    end)
    if type(res) ~= "table" then
      if not errors.is(terr) then
        terr = errors.new("TransportError", { message = "transport failed: " .. tostring(terr) })
      end
      return nil, terr
    end
    if type(res.status) ~= "number" then
      return nil, errors.new("TransportError", { message = "the transport returned no status" })
    end
    local headers = lower_headers(res.headers)
    res = { status = res.status, headers = headers, body = res.body or "" }
    local meta = { status = res.status, headers = headers }
    attempt.status = res.status
    if res.status >= 300 then
      attempt.hint_ms = retry.bounded_hint_ms(headers)
    end
    span:set("http.response.status_code", res.status)
    -- the debug attempt span gets the facts of its own try (telemetry.ts annotate)
    local current = tracer:current()
    if current and current ~= span then
      current:set("http.response.status_code", res.status)
    end

    local value, derr = tracer:with("distilled.decode", { debug = true }, function()
      return protocol.decode(ctx, op, res)
    end)
    if value == nil and derr ~= nil then
      return nil, derr, meta
    end
    return value, nil, meta
  end

  return protocol
end

return rest
