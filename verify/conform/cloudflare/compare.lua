-- Cloudflare conformance (task 19), the Lua side: runs every case of cases.jsonl through
-- the generated clients (clients/cloudflare/) and compares with ref.jsonl, Distilled's
-- answers (ts.mjs).
--
--   local compare = require("verify.conform.cloudflare.compare")
--   local report = compare.run(root [, { filter = "kv.", skip_models = { zero_trust = "why" },
--                                        patch_ref = fn(ref) }])
--   -- report = { cases, compared, mismatches = { { id, what, lua, ts } }, intended = { [why] = n },
--   --            skipped = { [reason] = n }, by_kind = { request = n, response = n, flow = n } }
--
--   lua verify/conform/cloudflare/run.lua [root] [filter]   -- prints the report
--
-- What is compared (intended differences are normalised by intended.lua):
--   request   method, URL path, query pairs (sorted), the auth/content/member headers, the
--             body (JSON parsed; multipart as parts)
--   response  success: the decoded value in TS names (lib.to_ts); failure: tag, message,
--             code, transient, retry_after
--   flow      every page's URL and the collected items (in TS names)
local json = require("distilled.json")
local errors = require("distilled.errors")
local schema = require("distilled.schema")
local compat = require("distilled.compat")
local lib = require("verify.conform.cloudflare.lib")
local intended = require("verify.conform.cloudflare.intended")

local compare = {}

-- headers that are transport or client details, not the protocol's
local IGNORED_HEADERS =
  { ["user-agent"] = true, accept = true, ["content-length"] = true, traceparent = true }

local function read_lines(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  local out = {}
  for line in string.gmatch(text, "[^\n]+") do
    out[#out + 1] = assert(json.decode(line))
  end
  return out
end

local function canon(v)
  return lib.canon(v)
end

-- a request body as { kind, json? | text? | parts? }
local function multipart_parts(body, content_type)
  local boundary = string.match(content_type or "", "boundary=([^;]+)")
  if not boundary then
    return nil
  end
  local parts = {}
  local delim = "--" .. boundary
  local pos = 1
  while true do
    local s = string.find(body, delim, pos, true)
    if not s then
      break
    end
    local after = s + #delim
    if string.sub(body, after, after + 1) == "--" then
      break
    end
    local nxt = string.find(body, delim, after, true)
    if not nxt then
      break
    end
    local chunk = string.sub(body, after + 2, nxt - 3) -- skip CRLF, drop trailing CRLF
    local hend = string.find(chunk, "\r\n\r\n", 1, true)
    local head, data = string.sub(chunk, 1, hend - 1), string.sub(chunk, hend + 4)
    local name = string.match(head, 'name="([^"]*)"')
    local filename = string.match(head, 'filename="([^"]*)"')
    local ct = string.match(head, "[Cc]ontent%-[Tt]ype: ([^\r\n]+)")
    local part = { name = name }
    if filename then
      part.filename = filename
      part.content_type = ct
      part.text = data
    else
      part.value = data
    end
    parts[#parts + 1] = part
    pos = nxt
  end
  return parts
end

local function body_view(kind_or_body, content_type, ts)
  if ts then
    local b = kind_or_body
    if b.kind == "none" then
      return { kind = "none" }
    elseif b.kind == "multipart" then
      return { kind = "multipart", parts = b.parts }
    end
    local text = b.text
    if text == nil then
      return { kind = "bytes", b64 = b.b64 }
    end
    local v = json.decode(text)
    if v ~= nil and string.find(content_type or "", "json", 1, true) then
      return { kind = "json", value = canon(v) }
    end
    return { kind = "bytes", text = text }
  end
  local body = kind_or_body
  if body == nil then
    return { kind = "none" }
  end
  if string.find(content_type or "", "multipart/form-data", 1, true) then
    return { kind = "multipart", parts = multipart_parts(body, content_type) }
  end
  local v = json.decode(body)
  if v ~= nil and string.find(content_type or "", "json", 1, true) then
    return { kind = "json", value = canon(v) }
  end
  return { kind = "bytes", text = body }
end

local function request_view(req, ts)
  local base, query = lib.split_url(req.url)
  local headers = {}
  for k, v in pairs(req.headers or {}) do
    local name = string.lower(k)
    if not IGNORED_HEADERS[name] then
      headers[name] = tostring(v)
    end
  end
  local ct = headers["content-type"]
  if ts then
    -- Distilled's body media type is part of the body; ours is a header
    ct = ct or (req.body and req.body.content_type)
    if ct and headers["content-type"] == nil then
      headers["content-type"] = ct
    end
  end
  -- a FormData body's media type (with its boundary) is set by fetch when it sends, so
  -- Distilled's request has none; both sides compare as "multipart/form-data"
  if
    (ct and string.find(ct, "multipart/form-data", 1, true))
    or (ts and req.body.kind == "multipart")
  then
    headers["content-type"] = "multipart/form-data"
    ct = ct or "multipart/form-data"
  end
  return {
    method = req.method,
    base = base,
    query = query,
    headers = headers,
    body = body_view(req.body, ct, ts),
  }
end

local function error_view(err)
  if not errors.is(err) then
    return { tag = tostring(err) }
  end
  local view = {
    tag = err.tag,
    message = err.message,
    code = type(err.code) == "number" and err.code or nil,
    transient = errors.is_transient(err),
    retry_after = err.retry_after,
  }
  -- a validation failure's mismatch, its path in TS names and 0-based indices
  local cause = err.cause
  if type(cause) == "table" and type(cause.path) == "table" then
    local p = json.array({})
    for i, k in ipairs(cause.path) do
      p[i] = type(k) == "number" and k - 1 or lib.ts_name(k)
    end
    view.cause_path = p
    view.cause_expected = cause.expected
  end
  return view
end

local function ts_error_view(e)
  return {
    tag = e.tag,
    message = e.message,
    code = e.code,
    transient = e.transient,
    retry_after = e.retry_after,
    cause_path = e.cause_path,
    cause_expected = e.cause_expected,
  }
end

-- the schema node of one item of a paginated operation
local function item_node(op, registry)
  local cur = op.output
  for seg in string.gmatch(op.pagination.items or "result", "[^%.]+") do
    local r = schema.resolve(cur, registry)
    if r and r.t == "list" then
      r = schema.resolve(r.item, registry)
    end
    local found
    for _, m in ipairs(r and r.members or {}) do
      if m.name == seg then
        found = m
      end
    end
    if not found then
      return nil
    end
    cur = found.schema
  end
  local r = schema.resolve(cur, registry)
  if r and r.t == "list" then
    return r.item
  end
  return cur
end

local function scripted(replies, sent)
  return function(req)
    sent[#sent + 1] = req
    local r = replies[math.min(#sent, #replies)]
    local headers = {}
    for k, v in pairs(r.headers or {}) do
      headers[string.lower(k)] = v
    end
    return { status = r.status or 200, headers = headers, body = r.body or "" }
  end
end

local function new_client(class, c, sent, replies)
  return class.new({
    api_token = lib.TOKEN,
    transport = scripted(replies, sent),
    sleep = function() end,
    retry = "none",
    validation = c.validation,
    jurisdiction = c.jurisdiction,
  })
end

-- deep copy of decoded JSON (inputs are mutated by nothing, but keep cases pristine)
local function lua_side(c, class, service, rename)
  local op = service.ops[c.op]
  local sent = {}
  if c.kind == "request" then
    local replies = { { status = 200, body = '{"success":true,"result":{}}' } }
    local client = new_client(class, c, sent, replies)
    local _, err = client[c.op](client, c.input)
    if sent[1] == nil then
      return { ok = false, error = error_view(err) }
    end
    return { ok = true, request = request_view(sent[1]) }
  elseif c.kind == "response" then
    local client = new_client(class, c, sent, c.replies)
    local v, err = client[c.op](client, c.input)
    if v == nil and err ~= nil then
      return { ok = false, error = error_view(err) }
    end
    return { ok = true, value = canon(lib.to_ts(op, v, service.shapes, rename)) }
  else
    local client = new_client(class, c, sent, c.replies)
    local items, err = client[c.op .. "_items"](client, c.input):collect()
    local urls = {}
    for i, req in ipairs(sent) do
      local base, query = lib.split_url(req.url)
      urls[i] = base .. "?" .. compat.concat(query, "&")
    end
    if items == nil then
      return { ok = false, error = error_view(err), urls = urls }
    end
    local node = item_node(op, service.shapes)
    local list = json.array({})
    for i, item in ipairs(items) do
      local fake = { output = node }
      list[i] = node and lib.to_ts(fake, item, service.shapes, rename) or item
    end
    return { ok = true, value = canon(list), urls = urls }
  end
end

local function ts_side(c, ref)
  if c.kind == "request" then
    if not ref.ok then
      return { ok = false, error = ts_error_view(ref.error) }
    end
    return { ok = true, request = request_view(ref, true) }
  end
  local o = ref.outcome
  local out
  if o.ok then
    out = { ok = true, value = canon(o.value) }
  else
    out = { ok = false, error = ts_error_view(o.error) }
  end
  if c.kind == "flow" then
    local urls = {}
    for i, u in ipairs(ref.urls) do
      local base, query = lib.split_url(u)
      urls[i] = base .. "?" .. compat.concat(query, "&")
    end
    out.urls = urls
  end
  return out
end

--- compare.run(root [, opts]) -> report
function compare.run(root, opts)
  opts = opts or {}
  local dir = root .. "/verify/conform/cloudflare/"
  local cases = read_lines(dir .. "cases.jsonl")
  local refs = {}
  for _, r in ipairs(read_lines(dir .. "ref.jsonl")) do
    if opts.patch_ref then
      opts.patch_ref(r) -- tests: a changed reference must show as a mismatch
    end
    refs[r.id] = r
  end
  local report = {
    cases = #cases,
    compared = 0,
    mismatches = {},
    intended = {},
    skipped = {},
    by_kind = {},
  }
  local function skip(why)
    report.skipped[why] = (report.skipped[why] or 0) + 1
  end
  local classes, services = {}, {}
  for _, c in ipairs(cases) do
    local ref = refs[c.id]
    if opts.filter and not string.find(c.id, opts.filter, 1, true) then
      skip("filtered out")
    elseif (opts.skip_models or {})[c.model] then
      skip(opts.skip_models[c.model])
    elseif ref == nil then
      skip("no reference answer (rerun ts.mjs)")
    elseif ref.missing then
      skip("operation not in Distilled's TS module")
    else
      if classes[c.model] == nil then
        classes[c.model] = require("cloudflare." .. c.model)
        services[c.model] = require("cloudflare." .. c.model .. ".service")
      end
      local lua = lua_side(c, classes[c.model], services[c.model], lib.rename_table(root, c.model))
      local ts = ts_side(c, ref)
      local why
      lua, ts, why = intended.normalize(c, lua, ts)
      if why then
        report.intended[why] = (report.intended[why] or 0) + 1
      end
      report.compared = report.compared + 1
      report.by_kind[c.kind] = (report.by_kind[c.kind] or 0) + 1
      local a, b = canon(lua), canon(ts)
      if a ~= b then
        report.mismatches[#report.mismatches + 1] = { id = c.id, lua = a, ts = b }
      end
    end
  end
  return report
end

--- compare.format(report) -> text
function compare.format(report, max)
  local out = {}
  out[#out + 1] = string.format(
    "cloudflare conform: %d cases, %d compared (requests %d, responses %d, flows %d), %d mismatches",
    report.cases,
    report.compared,
    report.by_kind.request or 0,
    report.by_kind.response or 0,
    report.by_kind.flow or 0,
    #report.mismatches
  )
  local whys = {}
  for why in pairs(report.intended) do
    whys[#whys + 1] = why
  end
  table.sort(whys)
  for _, why in ipairs(whys) do
    out[#out + 1] = string.format("  intended (%d): %s", report.intended[why], why)
  end
  local skips = {}
  for why in pairs(report.skipped) do
    skips[#skips + 1] = why
  end
  table.sort(skips)
  for _, why in ipairs(skips) do
    out[#out + 1] = string.format("  skipped (%d): %s", report.skipped[why], why)
  end
  for i, m in ipairs(report.mismatches) do
    if i > (max or 20) then
      out[#out + 1] = "  ..."
      break
    end
    out[#out + 1] = "MISMATCH " .. m.id .. "\n  lua " .. m.lua .. "\n  ts  " .. m.ts
  end
  return compat.concat(out, "\n")
end

return compare
