-- dl conform, requests: the request the generated Lua client sends for each case, against
-- the one Distilled built (ref/<provider>/requests.jsonl).
--
-- Compared: method; URL path (raw bytes), query content (decoded pairs as a multiset),
-- query order and query encoding (reported separately); the headers that carry meaning
-- (content-type, authorization, member-bound headers); the body as parsed JSON when the
-- content type is JSON, otherwise as bytes. When both sides refuse the input, the error
-- tags are compared.
local errors = require("distilled.errors")
local schema = require("distilled.schema")
local lib = require("verify.conform.lib")
local diff = require("verify.conform.diff")
local env = require("verify.conform.env")

local check = {}

-- The request the Lua client hands its transport, or the error it returns first.
local function lua_request(client, case)
  local captured = env.capture
  captured.req = nil
  local method = client[case.op]
  if type(method) ~= "function" then
    return { ok = false, error = { tag = "NoSuchOperation", message = case.op } }
  end
  local _, err = method(client, lib.to_lua(case.input))
  local req = captured.req
  if req then
    local body
    if req.body ~= nil then
      body = { kind = "bytes", text = req.body }
    else
      body = { kind = "none" }
    end
    return { ok = true, method = req.method, url = req.url, headers = req.headers, body = body }
  end
  return {
    ok = false,
    error = { tag = err and err.tag or "NoError", message = err and err.message },
  }
end

local function header_names(service, op_name)
  local names = { "content-type", "authorization" }
  local op = service.ops[op_name]
  local node = op and schema.resolve(op.input, service.shapes)
  for _, m in ipairs(node and node.members or {}) do
    if m.bind == "header" then
      names[#names + 1] = string.lower(m.wire or m.name)
    end
  end
  return names
end

local function unescape_param(v)
  v = string.gsub(v, "%%22", '"')
  v = string.gsub(v, "%%0D", "\r")
  v = string.gsub(v, "%%0A", "\n")
  return v
end

--- parse_multipart(body, content_type) -> parts { name, filename?, content_type?, data } | nil, why
function check.parse_multipart(body, content_type)
  local boundary = string.match(content_type or "", "boundary=([^;]+)")
  if not boundary or not body then
    return nil, "no boundary in content-type " .. tostring(content_type)
  end
  local delim = "--" .. boundary
  local parts = {}
  local pos = string.find(body, delim, 1, true)
  if pos ~= 1 then
    return nil, "body does not start with the boundary"
  end
  pos = pos + #delim
  while true do
    if string.sub(body, pos, pos + 1) == "--" then
      break -- closing delimiter
    end
    if string.sub(body, pos, pos + 1) ~= "\r\n" then
      return nil, "no CRLF after a boundary at byte " .. pos
    end
    pos = pos + 2
    local head_end = string.find(body, "\r\n\r\n", pos, true)
    if not head_end then
      return nil, "part headers do not end"
    end
    local head = string.sub(body, pos, head_end - 1)
    local next_delim = string.find(body, "\r\n" .. delim, head_end + 4, true)
    if not next_delim then
      return nil, "part does not end with the boundary"
    end
    local part = { data = string.sub(body, head_end + 4, next_delim - 1) }
    for line in string.gmatch(head .. "\r\n", "(.-)\r\n") do
      local lower = string.lower(line)
      if string.find(lower, "^content%-disposition:") then
        part.name = unescape_param(string.match(line, ' name="([^"]*)"') or "")
        local fname = string.match(line, ' filename="([^"]*)"')
        part.filename = fname and unescape_param(fname)
      elseif string.find(lower, "^content%-type:") then
        part.content_type = string.match(line, "^[^:]+:%s*(.-)%s*$")
      end
    end
    parts[#parts + 1] = part
    pos = next_delim + 2 + #delim
  end
  return parts
end

-- Distilled hands a FormData to the HTTP client, which serializes it (undici): text values
-- get CRLF line breaks there. Do the same to the dumped value before comparing bytes.
local function crlf(s)
  s = string.gsub(s, "\r\n", "\n")
  s = string.gsub(s, "\r", "\n")
  return (string.gsub(s, "\n", "\r\n"))
end

local function compare_multipart(want, got, out)
  local ct = got.headers["content-type"]
  if not string.find(ct or "", "^multipart/form%-data; boundary=") then
    out[#out + 1] =
      { path = "headers.content-type", a = "multipart/form-data; boundary=...", b = ct }
  end
  local parts, why = check.parse_multipart(got.body.text, ct)
  if not parts then
    out[#out + 1] = { path = "body", a = "multipart", b = "unparseable: " .. why }
    return out
  end
  local n = math.max(#want.body.parts, #parts)
  for i = 1, n do
    local w, g = want.body.parts[i], parts[i]
    local p = "body.parts[" .. (i - 1) .. "]"
    if not w or not g then
      out[#out + 1] = { path = p, a = w and w.name, b = g and g.name }
    else
      if w.name ~= g.name then
        out[#out + 1] = { path = p .. ".name", a = w.name, b = g.name }
      end
      local wdata
      if w.filename ~= nil then
        wdata = lib.bytes_of(w)
        if w.filename ~= g.filename then
          out[#out + 1] = { path = p .. ".filename", a = w.filename, b = g.filename }
        end
        local wct = (w.content_type ~= nil and w.content_type ~= "") and w.content_type
          or "application/octet-stream"
        if wct ~= g.content_type then
          out[#out + 1] = { path = p .. ".content_type", a = wct, b = g.content_type }
        end
      else
        wdata = crlf(w.value)
        if g.filename ~= nil then
          out[#out + 1] = { path = p .. ".filename", a = nil, b = g.filename }
        end
      end
      if wdata ~= g.data then
        out[#out + 1] = { path = p .. ".data", a = wdata, b = g.data }
      end
    end
  end
  return out
end

local function body_bytes(rec)
  if rec == nil or rec.kind == "none" then
    return nil
  end
  return lib.bytes_of(rec)
end

--- compare(case, want, got, service) -> diffs
function check.compare(case, want, got, service)
  local out = {}
  if want.ok ~= got.ok then
    out[#out + 1] = {
      path = "outcome",
      a = want.ok and "request"
        or ("error " .. tostring(want.error.tag) .. ": " .. tostring(want.error.message)),
      b = got.ok and "request"
        or ("error " .. tostring(got.error.tag) .. ": " .. tostring(got.error.message)),
    }
    return out
  end
  if not want.ok then
    if want.error.tag ~= got.error.tag then
      out[#out + 1] = { path = "error.tag", a = want.error.tag, b = got.error.tag }
    end
    return out
  end
  if want.method ~= got.method then
    out[#out + 1] = { path = "method", a = want.method, b = got.method }
  end
  diff.urls(want.url, got.url, out)
  for _, name in ipairs(header_names(service, case.op)) do
    local a, b = want.headers[name], got.headers[name]
    -- multipart: Distilled's request has no content-type (fetch derives it from the
    -- FormData); compare_multipart checks Lua's
    if a ~= b and not (name == "content-type" and want.body.kind == "multipart") then
      out[#out + 1] = { path = "headers." .. name, a = a, b = b }
    end
  end
  if want.body.kind == "multipart" then
    return compare_multipart(want, got, out)
  end
  diff.bodies(body_bytes(want.body), body_bytes(got.body), want.headers["content-type"], out)
  return out
end

--- run(ctx) -> results: { { id, case_file, line, diffs } ... }
function check.run(ctx)
  local cases = lib.read_lines(ctx.cases_dir .. "/requests.jsonl")
  local refs = lib.read_lines(ctx.ref_dir .. "/requests.jsonl")
  local by_id = {}
  for _, r in ipairs(refs) do
    by_id[r.id] = r
  end
  local client = env.client(ctx)
  local results = {}
  for i, case in ipairs(cases) do
    local want = by_id[case.id]
    local result = { id = case.id, line = i, file = "requests.jsonl", case = case }
    if not want then
      result.diffs = { { path = "ref", a = "(no reference: rerun without --replay)", b = "" } }
    elseif ctx.skip and ctx.skip(case, ctx) then
      result.skipped = ctx.skip(case, ctx)
    else
      local got = lua_request(client, case)
      result.got = got
      result.diffs = check.compare(case, want, got, ctx.service)
    end
    results[#results + 1] = result
  end
  return results
end

check._errors = errors
return check
