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
    if a ~= b then
      out[#out + 1] = { path = "headers." .. name, a = a, b = b }
    end
  end
  if want.body.kind == "multipart" or got.body.kind == "multipart" then
    out[#out + 1] = { path = "body.kind", a = want.body.kind, b = got.body.kind }
    return out
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
