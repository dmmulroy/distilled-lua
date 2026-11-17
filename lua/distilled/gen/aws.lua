-- AWS model support for the generator: native Smithy AWS models (models/aws/*.json).
--
-- Port of the AWS half of Distilled's generator, packages/aws/scripts/spec.ts (awsSpec):
-- the protocol pick, the service facts the runtime needs (sdkId, SigV4 name, version,
-- XML namespace, endpoint rules), the error classes (`errors.override`: errorTag tags,
-- awsRetryCategories, inferCategoriesFromName, the awsQueryError codes, synthetic
-- errors), the operation facts (hostPrefix, staticContextParams, httpChecksum, the
-- paginated trait merged over the service's) and the serialization traits on members
-- (xmlName, xmlFlattened, xmlAttribute, xmlNamespace, ec2QueryName, timestampFormat,
-- jsonName only in restJson1, idempotencyToken, contextParam, hostLabel, mediaType,
-- streaming, httpPrefixHeaders, httpQueryParams).
--
-- gen/init.lua, gen/model.lua, gen/shapes.lua, gen/ops.lua and gen/types.lua call the
-- hooks below when the model is an AWS model (`ctx.aws` is set); nothing changes for
-- other models. The client file (init.lua) and the endpoint rules (endpoints.lua) of an
-- AWS client are written here; the runtime is lua/distilled/aws/.
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local json = require("distilled.json")
local naming = require("distilled.gen.naming")

local aws = {}

-- PROTOCOL_ANNOTATIONS: the wire protocols the runtime implements (rpcv2Cbor is not
-- one; Distilled skips it and so do we).
aws.PROTOCOLS = {
  ["aws.protocols#restJson1"] = "restJson1",
  ["aws.protocols#awsJson1_0"] = "awsJson1_0",
  ["aws.protocols#awsJson1_1"] = "awsJson1_1",
  ["aws.protocols#awsQuery"] = "awsQuery",
  ["aws.protocols#ec2Query"] = "ec2Query",
  ["aws.protocols#restXml"] = "restXml",
}
local RPC = { awsJson1_0 = true, awsJson1_1 = true, awsQuery = true, ec2Query = true }
local JSON = { restJson1 = true, awsJson1_0 = true, awsJson1_1 = true }

--- aws.is_aws_model(doc) -> true when a service shape carries aws.api#service
function aws.is_aws_model(doc)
  for _, s in pairs(doc.shapes or {}) do
    if type(s) == "table" and s.type == "service" and s.traits and s.traits["aws.api#service"] then
      return true
    end
  end
  return false
end

local function strip(m, t, keys, what, where)
  local removed = {}
  local order = m.order[t]
  for _, k in ipairs(keys) do
    if t[k] ~= nil then
      t[k] = nil
      removed[#removed + 1] = k
      if order then
        for i = #order, 1, -1 do
          if order[i] == k then
            table.remove(order, i)
          end
        end
      end
    end
  end
  if #removed > 0 and what then
    local message = where .. ": " .. what .. " " .. compat.concat(removed, ", ") .. " dropped"
    local seen = false
    for _, w in ipairs(m.warnings) do
      seen = seen or w == message
    end
    if not seen then
      m.warnings[#m.warnings + 1] = message
    end
  end
end

-- Telemetry the Lua runtime does not do for AWS operations (message-attribute and
-- Lambda-context injection, span name templates, attribute copies, streamed-output
-- spans, host rules): the keys are dropped, the spans keep their name and attributes.
-- Distilled injects trace context into SQS/SNS/EventBridge/Lambda payloads; we do not
-- (named in verify/features/aws.md).
local DROPPED_OP_TELEMETRY = { "nameTemplate", "inject", "extract", "copy", "stream" }

--- aws.context(m, spec) -> info | nil, message
-- info = { protocol, rpc, json, service_name, sdk_id, signing_name, sigv4a, auth,
--          version, xmlns, query_compatible, rules, paginated, default_ts }
function aws.context(m, spec)
  local svc = m.service
  if not svc or not (svc.traits and svc.traits["aws.api#service"]) then
    return nil
  end
  local traits = svc.traits
  local protocol
  for _, k in ipairs(m:keys(traits)) do
    if aws.PROTOCOLS[k] and not protocol then
      protocol = aws.PROTOCOLS[k]
    end
  end
  if not protocol then
    return nil, m.service_id .. ": no supported AWS protocol"
  end
  local service_name = naming.local_name(m.service_id)
  local sigv4 = traits["aws.auth#sigv4"]
  local auth = "sigv4"
  if sigv4 == nil then
    if traits["aws.auth#sigv2"] ~= nil then
      auth = "sigv2"
    elseif traits["smithy.api#httpBearerAuth"] ~= nil then
      auth = "bearer"
    end
  end
  local info = {
    protocol = protocol,
    rpc = RPC[protocol] == true,
    json = JSON[protocol] == true,
    service_name = service_name,
    sdk_id = traits["aws.api#service"].sdkId,
    endpoint_prefix = traits["aws.api#service"].endpointPrefix,
    signing_name = sigv4 and sigv4.name or service_name,
    sigv4a = traits["aws.auth#sigv4a"] ~= nil or nil,
    auth = auth,
    version = svc.version or "",
    xmlns = type(traits["smithy.api#xmlNamespace"]) == "table"
        and traits["smithy.api#xmlNamespace"].uri
      or nil,
    query_compatible = traits["aws.protocols#awsQueryCompatible"] ~= nil or nil,
    rules = traits["smithy.rules#endpointRuleSet"],
    paginated = traits["smithy.api#paginated"],
    -- namedTimestampExpr: epoch-seconds in the JSON protocols, date-time elsewhere
    default_ts = JSON[protocol] and "epoch-seconds" or "date-time",
  }
  -- telemetry the runtime does not do: dropped with a warning (see above)
  local tel = traits["com.distilled.telemetry#service"]
  if type(tel) == "table" then
    strip(m, tel, { "hosts" }, "telemetry", "service")
  end
  for _, op in ipairs(m.operations) do
    local t = op.def.traits and op.def.traits["com.distilled.telemetry#operation"]
    if type(t) == "table" then
      strip(m, t, DROPPED_OP_TELEMETRY, "telemetry", op.id)
    end
  end
  return info
end

---------------------------------------------------------------------------------------
-- operations
---------------------------------------------------------------------------------------

--- aws.http(ctx, op) -> the HTTP facts of an RPC operation (POST /), or nil
function aws.http(ctx, op)
  if ctx.aws.rpc then
    return { method = "POST", uri = "/", code = 200 }
  end
  return nil
end

-- the keys of Smithy's paginated trait (opensearchserverless adds maxResults: dropped)
local SMITHY_PAGINATED = { inputToken = true, outputToken = true, items = true, pageSize = true }

--- aws.paginated(ctx, pg) -> the operation's trait over the service's (mergePaginated)
function aws.paginated(ctx, op, pg)
  local service = ctx.aws.paginated
  if pg == nil or type(pg) ~= "table" then
    return pg
  end
  if type(service) ~= "table" then
    service = {}
  end
  local m = ctx.model
  local out = {}
  local keys = {}
  for _, k in ipairs(m:keys(service)) do
    if SMITHY_PAGINATED[k] then
      out[k] = service[k]
      keys[#keys + 1] = k
    end
  end
  for _, k in ipairs(m:keys(pg)) do
    if SMITHY_PAGINATED[k] then
      if out[k] == nil then
        keys[#keys + 1] = k
      end
      out[k] = pg[k]
    end
  end
  m.order[out] = keys
  return out
end

-- the streaming union member of a structure: member, union id | nil
local function stream_member(m, id)
  local def = m.shapes[id]
  for _, mem in ipairs(def and m:members(def) or {}) do
    local t = m.shapes[mem.target]
    if t and t.type == "union" and t.traits and t.traits["smithy.api#streaming"] ~= nil then
      return mem, mem.target
    end
  end
  return nil
end

--- aws.event_stream(ctx, op) -> nil: sets op.stream for an operation whose output or
-- input holds an event stream (a @streaming union), as the client's `_stream` method
-- reads it (docs/interfaces.md, the stream section):
--   op.stream = { framing = "aws_eventstream", member = <output member>, item = S.ref(union),
--                 input = { member = <input member>, item = S.ref(union) } | nil }
-- Every operation with an input event stream has an output one too (the 10 AWS has).
-- The error shapes of the output union become the operation's errors, so their classes
-- are generated: an exception event ends the stream with that class (the AWS SDKs throw
-- it; Distilled yields it as a union member).
function aws.event_stream(ctx, op)
  local m = ctx.model
  local out_mem, out_union = stream_member(m, op.output)
  local in_mem, in_union = stream_member(m, op.input)
  if not out_mem and not in_mem then
    return nil
  end
  if not out_mem then
    return "event streams with no output event stream"
  end
  local stream = {
    framing = "aws_eventstream",
    member = out_mem.name,
    item = emit.call("S.ref", naming.local_name(out_union)),
  }
  if in_mem then
    stream.input = {
      member = in_mem.name,
      item = emit.call("S.ref", naming.local_name(in_union)),
    }
  end
  op.stream = stream
  local seen = {}
  for _, e in ipairs(op.errors) do
    seen[e] = true
  end
  local union = m.shapes[out_union]
  for _, mem in ipairs(m:members(union)) do
    local t = m.shapes[mem.target]
    if t and t.traits and t.traits["smithy.api#error"] ~= nil and not seen[mem.target] then
      seen[mem.target] = true
      op.errors[#op.errors + 1] = mem.target
    end
  end
  return nil
end

--- aws.op_facts(ctx, op) -> the AWS keys of the op descriptor (emit values) | nil
function aws.op_facts(ctx, op)
  local traits = op.def.traits or {}
  local out = {}
  local any = false
  local endpoint = traits["smithy.api#endpoint"]
  if type(endpoint) == "table" and type(endpoint.hostPrefix) == "string" then
    out.host_prefix = endpoint.hostPrefix
    any = true
  end
  local static = traits["smithy.rules#staticContextParams"]
  if type(static) == "table" then
    local params = {}
    for _, k in ipairs(ctx.model:keys(static)) do
      local v = static[k]
      params[k] = type(v) == "table" and v.value or v
    end
    out.static_params = params
    any = true
  end
  local checksum = traits["aws.protocols#httpChecksum"]
  if checksum ~= nil or traits["smithy.api#httpChecksumRequired"] ~= nil then
    local c = {}
    if type(checksum) == "table" then
      c.algorithm_member = checksum.requestAlgorithmMember
      c.required = checksum.requestChecksumRequired == true or nil
    end
    if traits["smithy.api#httpChecksumRequired"] ~= nil then
      c.required = true
    end
    if c.algorithm_member or c.required then
      out.checksum = c
      any = true
    end
  end
  if traits["aws.auth#unsignedPayload"] ~= nil then
    out.unsigned_payload = true
    any = true
  end
  local auth = traits["smithy.api#auth"]
  if traits["smithy.api#optionalAuth"] ~= nil or (type(auth) == "table" and #auth == 0) then
    out.optional_auth = true
    any = true
  end
  if traits["aws.customizations#s3UnwrappedXmlOutput"] ~= nil then
    out.unwrapped_output = true
    any = true
  end
  local compression = traits["smithy.api#requestCompression"]
  if type(compression) == "table" then
    -- middleware/compression.ts: gzip bodies of at least 10 KiB (CloudWatch PutMetricData)
    for _, e in ipairs(compression.encodings or {}) do
      if e == "gzip" then
        out.gzip = true
        any = true
      end
    end
  end
  return any and out or nil
end

---------------------------------------------------------------------------------------
-- shapes
---------------------------------------------------------------------------------------

local function xmlns_value(t)
  if type(t) ~= "table" or type(t.uri) ~= "string" then
    return nil
  end
  return { uri = t.uri, prefix = t.prefix }
end

--- aws.member(ctx, info, v): AWS member keys on the emit value v of a member
function aws.member(ctx, info, v)
  local a = ctx.aws
  local traits = info.traits or {}
  local bind = v.bind or "body"
  if a.rpc then
    -- the RPC protocols put every member in the body, under its member name
    v.bind, v.wire, v.greedy = nil, nil, nil
    bind = "body"
  else
    if traits["smithy.api#httpPrefixHeaders"] ~= nil then
      v.bind = "prefix_headers"
      v.wire = traits["smithy.api#httpPrefixHeaders"]
      bind = "prefix_headers"
    elseif traits["smithy.api#httpQueryParams"] ~= nil then
      v.bind = "query_params"
      v.wire = nil
      bind = "query_params"
    end
  end
  if bind == "body" and not (a.protocol == "restJson1") then
    -- awsJson ignores @jsonName (aws-json-1_1-protocol.html), the XML protocols read xml_name
    v.wire = nil
  end
  -- required: @required unless @clientOptional; @default does not make a member required
  local required = traits["smithy.api#required"] ~= nil
    and traits["smithy.api#clientOptional"] == nil
  v.required = required or nil
  if traits["smithy.api#timestampFormat"] ~= nil then
    v.ts = traits["smithy.api#timestampFormat"]
  end
  if traits["smithy.api#xmlName"] ~= nil then
    v.xml_name = traits["smithy.api#xmlName"]
  end
  if traits["aws.protocols#ec2QueryName"] ~= nil then
    v.ec2_name = traits["aws.protocols#ec2QueryName"]
  end
  if traits["smithy.api#xmlFlattened"] ~= nil then
    v.flat = true
  end
  if traits["smithy.api#xmlAttribute"] ~= nil then
    v.attr = true
  end
  local ns = xmlns_value(traits["smithy.api#xmlNamespace"])
  if ns then
    v.xmlns = ns
  end
  if traits["smithy.api#idempotencyToken"] ~= nil then
    v.idempotency_token = true
  end
  local cp = traits["smithy.rules#contextParam"]
  if type(cp) == "table" and type(cp.name) == "string" then
    v.context_param = cp.name
  end
  if traits["smithy.api#hostLabel"] ~= nil then
    v.host_label = true
  end
  -- event stream bindings (distilled.aws.event_stream reads them)
  if traits["smithy.api#eventPayload"] ~= nil then
    v.event = "payload"
  elseif traits["smithy.api#eventHeader"] ~= nil then
    v.event = "header"
  end
end

-- timestampFormat of a list member / map value: an inline timestamp node for the element
local function element_with_format(ctx, mem, node)
  local traits = mem and mem.traits or {}
  local fmt = traits["smithy.api#timestampFormat"]
  if fmt == nil then
    return node
  end
  local target = mem.target
  local def = ctx.model.shapes[target]
  local kind = ctx.model:scalar(target)
  if kind ~= "timestamp" and not (def and def.type == "timestamp") then
    return node
  end
  return { t = "timestamp", format = fmt }
end

--- aws.node(ctx, id, def, node) -> the node with AWS keys (a union becomes a struct)
function aws.node(ctx, id, def, node)
  local shapes = require("distilled.gen.shapes")
  local traits = def.traits or {}
  if def.type == "union" then
    -- a Smithy union is a tagged union: exactly one member set, keyed by member name
    local members = {}
    for _, info in ipairs(shapes.members(ctx, def, id)) do
      local v = shapes.member_value(ctx, info)
      v.required = nil
      if traits["smithy.api#streaming"] ~= nil then
        -- an event stream's error member: the class an exception event ends the stream with
        local target = ctx.model.shapes[info.target]
        local tt = target and target.traits or {}
        if tt["smithy.api#error"] ~= nil then
          local tag = tt["aws.codegen#errorTag"]
          v.error = type(tag) == "string" and tag or naming.local_name(info.target)
        end
      end
      members[#members + 1] = v
    end
    node = {
      t = "struct",
      name = naming.local_name(id),
      members = emit.list(members),
      union = true,
    }
    if traits["smithy.api#sensitive"] ~= nil then
      node.sensitive = true
    end
  end
  if def.type == "structure" or def.type == "union" then
    if traits["smithy.api#xmlName"] ~= nil then
      node.xml_name = traits["smithy.api#xmlName"]
    end
    local ns = xmlns_value(traits["smithy.api#xmlNamespace"])
    if ns then
      node.xmlns = ns
    end
  elseif def.type == "list" or def.type == "set" then
    local mt = def.member and def.member.traits or {}
    if mt["smithy.api#xmlName"] ~= nil then
      node.item_xml_name = mt["smithy.api#xmlName"]
    end
    local ns = xmlns_value(mt["smithy.api#xmlNamespace"])
    if ns then
      node.item_xmlns = ns
    end
    local item_def = ctx.model.shapes[def.member.target]
    if item_def and (item_def.type == "structure" or item_def.type == "union") then
      node.item_id = naming.local_name(def.member.target)
    end
    node.item = element_with_format(ctx, def.member, node.item)
    if traits["smithy.api#sparse"] ~= nil then
      node.item = emit.call("S.nullable", node.item)
    end
  elseif def.type == "map" then
    local kt = def.key and def.key.traits or {}
    local vt = def.value and def.value.traits or {}
    if kt["smithy.api#xmlName"] ~= nil then
      node.key_name = kt["smithy.api#xmlName"]
    end
    if vt["smithy.api#xmlName"] ~= nil then
      node.value_name = vt["smithy.api#xmlName"]
    end
    local kns, vns =
      xmlns_value(kt["smithy.api#xmlNamespace"]), xmlns_value(vt["smithy.api#xmlNamespace"])
    if kns then
      node.key_xmlns = kns
    end
    if vns then
      node.value_xmlns = vns
    end
    node.value = element_with_format(ctx, def.value, node.value)
    if traits["smithy.api#sparse"] ~= nil then
      node.value = emit.call("S.nullable", node.value)
    end
  elseif def.type == "timestamp" then
    if traits["smithy.api#timestampFormat"] ~= nil then
      node.format = traits["smithy.api#timestampFormat"]
    end
  end
  if traits["smithy.api#mediaType"] ~= nil then
    node.media_type = traits["smithy.api#mediaType"]
  end
  if traits["smithy.api#streaming"] ~= nil then
    node.streaming = true
  end
  return node
end

---------------------------------------------------------------------------------------
-- errors (spec.ts errors.override)
---------------------------------------------------------------------------------------

-- AWS_THROTTLING_CODES and AWS_TRANSIENT_CODES (botocore retries/standard.py)
aws.THROTTLING_CODES = {}
for _, c in ipairs({
  "Throttling",
  "ThrottlingException",
  "ThrottledException",
  "RequestThrottledException",
  "TooManyRequestsException",
  "ProvisionedThroughputExceededException",
  "TransactionInProgressException",
  "RequestLimitExceeded",
  "BandwidthLimitExceeded",
  "LimitExceededException",
  "RequestThrottled",
  "SlowDown",
  "PriorRequestNotComplete",
  "EC2ThrottledException",
}) do
  aws.THROTTLING_CODES[c] = true
end
aws.TRANSIENT_CODES = {
  RequestTimeout = true,
  RequestTimeoutException = true,
  PriorRequestNotComplete = true,
}
local TRANSIENT_STATUSES = { [500] = true, [502] = true, [503] = true, [504] = true }

--- aws.retry_categories(code, status) -> list (awsRetryCategories)
function aws.retry_categories(code, status)
  if aws.THROTTLING_CODES[code] then
    return { "ThrottlingError", "RetryableError" }
  end
  if aws.TRANSIENT_CODES[code] or (status ~= nil and TRANSIENT_STATUSES[status]) then
    return { "RetryableError" }
  end
  return {}
end

--- aws.name_categories(name) -> list (inferCategoriesFromName)
function aws.name_categories(error_name)
  local out = {}
  local name = string.lower(error_name)
  local function ends(s)
    return string.sub(name, -#s) == s
  end
  local function has(s)
    return string.find(name, s, 1, true) ~= nil
  end
  if name == "dependencyviolation" or ends("inuse") then
    out[#out + 1] = "DependencyViolationError"
  end
  if has("alreadyexists") or ends("duplicate") then
    out[#out + 1] = "AlreadyExistsError"
  end
  if name == "cidrconflict" or name == "idempotentparametermismatch" then
    out[#out + 1] = "ConflictError"
  end
  if
    has("accessdenied")
    or has("unauthorized")
    or name == "authfailure"
    or name == "invalidclienttokenid"
    or name == "signaturedoesnotmatch"
  then
    out[#out + 1] = "AuthError"
  end
  if ends("limitexceeded") then
    out[#out + 1] = "ThrottlingError"
  end
  if has("internalerror") or has("serviceunavailable") then
    out[#out + 1] = "ServerError"
  end
  return out
end

--- aws.error_class(ctx, id, d) -> d with the AWS tag, categories, fields and wire facts
-- (d from gen/errors.lua class: its categories already hold errorCategories' reading of
-- httpError, retryable and distilled.errors#categories)
function aws.error_class(ctx, id, d)
  local def = ctx.model.shapes[id]
  local traits = def.traits or {}
  local name = naming.local_name(id)
  local tag = traits["aws.codegen#errorTag"]
  if type(tag) ~= "string" then
    tag = name
  end
  d.tag = tag
  local query = traits["aws.protocols#awsQueryError"]
  local status = traits["smithy.api#httpError"]
  if status == nil and type(query) == "table" then
    status = query.httpResponseCode
  end
  local seen, cats = {}, {}
  -- d.categories is an emit.list (gen/errors.lua errorCategories of the traits)
  local base = d.categories
  if emit.is_list(base) then
    base = base.items
  end
  for _, c in ipairs(base or {}) do
    if not seen[c] then
      seen[c] = true
      cats[#cats + 1] = c
    end
  end
  local extra = aws.retry_categories(type(query) == "table" and query.code or name, status)
  for _, c in ipairs(aws.name_categories(name)) do
    extra[#extra + 1] = c
  end
  for _, c in ipairs(extra) do
    if not seen[c] then
      seen[c] = true
      cats[#cats + 1] = c
    end
  end
  d.categories = emit.list(cats)
  -- Distilled's AWS retry backs off on the ThrottlingError category (awsRetryCategories,
  -- AWS_THROTTLING_CODES): a @retryable class without `throttling: true` is throttling
  -- too when its code says so (ThrottlingException, RequestLimitExceeded)
  if seen.ThrottlingError and d.retryable then
    d.throttling = true
  end
  -- the message member is the instance's message (Message is folded onto it)
  local fields = {}
  for _, mem in ipairs(ctx.model:members(def)) do
    if mem.name ~= "message" and mem.name ~= "Message" then
      fields[#fields + 1] = mem.name
    end
  end
  d.fields = #fields > 0 and emit.list(fields) or nil
  -- wire facts for the runtime's code table (aws/errors.lua)
  local wire = {}
  if type(query) == "table" and type(query.code) == "string" then
    wire.query_code = query.code
  end
  if type(status) == "number" then
    wire.status = status
  end
  local synthetic = traits["aws.codegen#synthetic"]
  if type(synthetic) == "table" and type(synthetic.from) == "string" then
    local message = synthetic.message
    if type(message) == "table" then
      message = { includes = message.includes, matches = message.matches }
    end
    wire.synthetic = { from = synthetic.from, message = message }
  end
  -- error members bound to response headers (restJson1 / restXml)
  local headers = {}
  for _, mem in ipairs(ctx.model:members(def)) do
    local h = mem.traits["smithy.api#httpHeader"]
    if type(h) == "string" then
      local kind = ctx.model:scalar(mem.target)
      local tdef = ctx.model.shapes[mem.target]
      if tdef and tdef.type == "enum" then
        kind = "string"
      end
      headers[#headers + 1] = { name = mem.name, header = string.lower(h), kind = kind }
    end
  end
  if #headers > 0 then
    wire.headers = emit.list(headers)
  end
  -- the error body's registry node: a JSON error body with fields beyond the message
  -- decodes through it (gen/init.lua adds `root` to the registry roots)
  local p = ctx.aws and ctx.aws.protocol
  if #fields > 0 and (p == "awsJson1_0" or p == "awsJson1_1" or p == "restJson1") then
    wire.shape = name
    wire.root = id
  end
  d.aws = wire
  return d
end

---------------------------------------------------------------------------------------
-- documentation
---------------------------------------------------------------------------------------

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

aws.DOC_LIMIT = 400

--- aws.doc_text(html) -> the first paragraph as plain text, at most DOC_LIMIT bytes
-- (AWS documentation is HTML; types.lua and README.md keep a summary, the AWS docs
-- have the rest)
function aws.doc_text(html)
  local first = string.match(html, "^%s*<p>(.-)</p>") or html
  local text = string.gsub(first, "<[^>]*>", "")
  text = string.gsub(text, "&(#?%w+);", function(e)
    if ENTITIES[e] then
      return ENTITIES[e]
    end
    local n = tonumber(string.match(e, "^#(%d+)$") or "")
    if n and n < 128 then
      return string.char(n)
    end
    return "&" .. e .. ";"
  end)
  -- a UTF-8 no-break space counts as space (stylua trims it at line ends)
  text = string.gsub(text, "\194\160", " ")
  text = string.gsub(string.gsub(text, "%s+", " "), "^ ", "")
  text = string.gsub(text, " $", "")
  if #text > aws.DOC_LIMIT then
    local cut = string.sub(text, 1, aws.DOC_LIMIT)
    -- do not split a UTF-8 sequence
    while #cut > 0 and string.byte(cut, -1) >= 128 and string.byte(cut, -1) < 192 do
      cut = string.sub(cut, 1, -2)
    end
    if #cut > 0 and string.byte(cut, -1) >= 192 then
      cut = string.sub(cut, 1, -2)
    end
    text = cut .. "..."
  end
  return text
end

---------------------------------------------------------------------------------------
-- files
---------------------------------------------------------------------------------------

-- The ruleset as JSON text in a long string: no Lua constant limits, decoded on first use.
local function long_string(text)
  local level = 0
  while string.find(text, "]" .. string.rep("=", level) .. "]", 1, true) do
    level = level + 1
  end
  local eq = string.rep("=", level)
  return "[" .. eq .. "[" .. text .. "]" .. eq .. "]"
end

-- The ruleset without its documentation strings (they are only for people).
local function rules_json(ctx)
  local rules = ctx.aws.rules
  local m = ctx.model
  -- iterative copy (gopher-lua's call stack): { src, dst } pairs
  local function new_like(v)
    if json.is_array(v) or (m.order[v] == nil and #v > 0) then
      return json.array({})
    end
    return json.object({})
  end
  local root = new_like(rules)
  local stack = { { rules, root } }
  while #stack > 0 do
    local pair = table.remove(stack)
    local src, dst = pair[1], pair[2]
    if json.is_array(dst) then
      for i = 1, #src do
        local v = src[i]
        if type(v) == "table" and v ~= json.null then
          local c = new_like(v)
          dst[i] = c
          stack[#stack + 1] = { v, c }
        else
          dst[i] = v
        end
      end
    else
      for _, k in ipairs(m:keys(src)) do
        local v = src[k]
        if k ~= "documentation" then
          if type(v) == "table" and v ~= json.null then
            local c = new_like(v)
            dst[k] = c
            stack[#stack + 1] = { v, c }
          else
            dst[k] = v
          end
        end
      end
    end
  end
  return json.encode(root)
end

--- aws.endpoints_file(plan) -> source of endpoints.lua
function aws.endpoints_file(plan)
  local lines = require("distilled.gen.writer").header(
    plan,
    plan.provider.title .. " endpoint rules (smithy.rules#endpointRuleSet), as JSON."
  )
  lines[#lines + 1] = "-- Decoded on the first call by distilled.aws.protocol."
  lines[#lines + 1] = "return " .. long_string(rules_json(plan.ctx))
  return compat.concat(lines, "\n") .. "\n"
end

local function md(s)
  return (string.gsub(s, "|", "\\|"))
end

--- aws.readme(plan) -> README.md of an AWS client
function aws.readme(plan)
  local spec, m, a = plan.provider, plan.model, plan.ctx.aws
  local out = {}
  local function add(s)
    out[#out + 1] = s or ""
  end
  add("# " .. spec.title .. " client (generated)")
  add()
  add("Generated by distilled-lua (generator " .. plan.generator_version .. ") from")
  add("`" .. ((m.path and string.match(m.path, "([^/]+)$")) or "model") .. "` (" .. m.hash .. ")")
  add("with the provider spec `" .. spec.name .. "`. Do not edit; regenerate with")
  add("`bin/distilled-lua package`. Runtime: `lua/distilled/aws/` (verify/features/aws.md).")
  add()
  local svc_doc = m.service.traits["smithy.api#documentation"]
  if type(svc_doc) == "string" then
    add(aws.doc_text(svc_doc))
    add()
  end
  add(
    "AWS service `"
      .. tostring(a.sdk_id)
      .. "`, protocol `"
      .. a.protocol
      .. "`, API version `"
      .. a.version
      .. "`, signing name `"
      .. tostring(a.signing_name)
      .. "`."
  )
  add()
  add("## Construct")
  add()
  add("```lua")
  add("local " .. spec.title .. ' = require("' .. spec.name .. '")')
  add("local client = " .. spec.title .. ".new({")
  add('  region = "us-east-1", -- default: AWS_REGION, AWS_DEFAULT_REGION, the profile')
  add('  host = require("distilled.host.popen")(), -- in Rex: require("distilled.host.rex")()')
  add("})")
  add("```")
  add()
  add("| Option | Meaning |")
  add("| --- | --- |")
  add("| `region` | the region; else `AWS_REGION`, `AWS_DEFAULT_REGION`, the profile's |")
  add(
    "| `credentials` | a source from `distilled.aws.credentials` (`chain{ profile }`,"
      .. " `static{...}`, `profile(name)`, ...); default: the provider chain |"
  )
  add("| `endpoint` | a custom endpoint URL (default from `AWS_ENDPOINT_URL`) |")
  if a.auth == "bearer" then
    add("| `token` | the bearer token (default from `AWS_BEARER_TOKEN`) |")
  end
  add("| `host`, `transport`, `retry`, `tracing`, `validation`, ... | the common client options |")
  add()
  add("Every method returns `value` or `nil, err`; `err.tag` is one of the operation's errors,")
  add("an AWS common error (`ThrottlingException`, `AccessDeniedException`, ...),")
  add("`UnknownAwsError` (nothing matched) or `ParseError`.")
  add()
  add("## Operations (" .. #plan.ops .. ")")
  add()
  add("| Method | HTTP | Summary |")
  add("| --- | --- | --- |")
  local ops_mod = require("distilled.gen.ops")
  for _, op in ipairs(plan.ops) do
    local doc = op.def.traits and op.def.traits["smithy.api#documentation"]
    local summary = type(doc) == "string" and aws.doc_text(doc) or ""
    if #summary > 160 then
      summary = string.sub(summary, 1, 157) .. "..."
      while string.byte(summary, -4) and string.byte(summary, -4) >= 128 do
        summary = string.sub(summary, 1, -5) .. "..."
      end
    end
    local method = "`" .. op.method_name .. "`"
    if op.pagination then
      method = method
        .. " (+ `"
        .. ops_mod.page_method(op, "pages")
        .. "`, `"
        .. ops_mod.page_method(op, "items")
        .. "`)"
    end
    local route = a.rpc and op.name or (op.http.method .. " " .. md(op.http.uri))
    add("| " .. method .. " | `" .. route .. "` | " .. md(summary) .. " |")
  end
  add()
  add("## Errors")
  add()
  add("| Tag | Categories |")
  add("| --- | --- |")
  for _, d in ipairs(plan.errors) do
    add("| `" .. d.tag .. "` | " .. compat.concat(d.categories.items, ", ") .. " |")
  end
  add()
  return compat.concat(out, "\n")
end

--- aws.title(sdk_id) -> a class name from the sdkId ("Route 53" -> "Route53")
function aws.title(sdk_id)
  local t = string.gsub(tostring(sdk_id), "[^%w]", "")
  if not string.find(t, "^%a") then
    t = "Aws" .. t
  end
  return t
end

--- aws.client_file(plan) -> source of init.lua
function aws.client_file(plan)
  local spec, a = plan.provider, plan.ctx.aws
  local b = emit.buffer()
  local writer = require("distilled.gen.writer")
  b:lines_of(
    writer.header(plan, spec.title .. ' client: what require("' .. spec.name .. '") returns.')
  )
  b:line("--")
  b:lines_of(emit.comment("local " .. spec.title .. ' = require("' .. spec.name .. '")'))
  b:lines_of(
    emit.comment(
      "local client = "
        .. spec.title
        .. '.new({ region = "us-east-1", host = require("distilled.host.popen")() })'
    )
  )
  b:lines_of(emit.comment("See README.md next to this file for the options and operations."))
  b:line('local Client = require("distilled.client")')
  b:line('local aws = require("distilled.aws.protocol")')
  b:blank()
  b:line("local MODULE = ... or " .. emit.string(spec.name))
  b:line('local service = require(MODULE .. ".service")')
  b:blank()
  -- the wire facts of the error classes: codes -> tags (aws/errors.lua reads them)
  local errs = {}
  for _, d in ipairs(plan.errors) do
    local w = d.aws or {}
    local e =
      { query_code = w.query_code, status = w.status, synthetic = w.synthetic, headers = w.headers }
    e.shape = w.shape
    if next(e) ~= nil then
      errs[d.tag] = e
    end
  end
  local args = {
    protocol = a.protocol,
    sdk_id = a.sdk_id,
    signing_name = a.signing_name,
    endpoint_prefix = a.endpoint_prefix,
    version = a.version,
    xmlns = a.xmlns,
    query_compatible = a.query_compatible,
    auth = a.auth ~= "sigv4" and a.auth or nil,
    sigv4a = a.sigv4a,
    default_ts = a.default_ts,
    errors = next(errs) and errs or nil,
    rules = a.rules and emit.raw('function()\n    return require(MODULE .. ".endpoints")\n  end')
      or nil,
  }
  if a.protocol == "awsJson1_0" or a.protocol == "awsJson1_1" then
    args.target = a.service_name
  end
  b:line("local protocol = aws.new(service, {")
  for _, k in ipairs(emit.sorted_keys(args)) do
    b:lines_of(emit.value(args[k], "  ", emit.key(k), ","))
  end
  b:line("})")
  b:blank()
  b:line("return Client.define({")
  b:line("  service = service,")
  b:line("  protocol = protocol,")
  b:line("  options = aws.options(" .. emit.string(a.auth) .. "),")
  b:line("})")
  return b:text()
end

return aws
