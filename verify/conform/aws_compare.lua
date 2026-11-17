-- dl conform aws, the Lua side: run each case of verify/conform/cases/aws.json through the
-- generated clients (clients/aws/<service>) with a scripted transport and diff the
-- request and the outcome against Distilled's (verify/conform/ref/aws/outcomes.json,
-- written by verify/conform/node/aws.mjs). Runs under lua, luajit and Rex.
--
--   lua verify/conform/aws_compare.lua <root>
--   rex do verify/conform/aws_compare.lua root=<root>
--
-- Compared: method, URL (host and path exactly; query as decoded pairs), the headers
-- Distilled sends (minus per-call ones: date, user agent, trace), the SigV4 credential
-- scope and signed header list, the body (JSON as values, form pairs sorted, XML
-- canonicalised), and the outcome: the decoded value, or the error tag, message and
-- fields. The signature itself differs with the body bytes (JSON key order), so only its
-- scope is compared.
local rex_api = rawget(_G, "rex")
local root
if rex_api then
  root = (rawget(rex_api, "args") or {}).root
else
  root = arg and arg[1]
end
root = root or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local compat = require("distilled.compat")
local aws_credentials = require("distilled.aws.credentials")
local pt = require("verify.lib.aws_protocol_tests")

local M = {}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local VOLATILE = {
  ["x-amz-date"] = true,
  ["user-agent"] = true,
  ["x-amz-user-agent"] = true,
  ["amz-sdk-invocation-id"] = true,
  ["amz-sdk-request"] = true,
  ["traceparent"] = true,
  ["x-amzn-trace-id"] = true,
  ["content-length"] = true,
  ["authorization"] = true,
  ["x-amz-content-sha256"] = true,
}

local function pct_decode(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function query_pairs(url, extra)
  local out = {}
  local q = string.match(url, "%?(.*)$") or ""
  for pair in string.gmatch(q, "[^&]+") do
    local k, v = string.match(pair, "^([^=]*)=?(.*)$")
    out[#out + 1] = pct_decode(k) .. "=" .. pct_decode(v)
  end
  for _, kv in ipairs(extra or {}) do
    out[#out + 1] = kv[1] .. "=" .. tostring(kv[2])
  end
  table.sort(out)
  return table.concat(out, "&")
end

local function base_url(url)
  return (string.gsub(url, "%?.*$", ""))
end

-- the credential scope and signed headers of an Authorization header
local function auth_scope(v)
  if type(v) ~= "string" then
    return tostring(v)
  end
  local cred = string.match(v, "Credential=[^/]+/%d+/([^,]+)")
  local signed = string.match(v, "SignedHeaders=([^,]+)")
  -- per-call headers Distilled may or may not sign
  local kept = {}
  for h in string.gmatch(signed or "", "[^;]+") do
    if not VOLATILE[h] or h == "x-amz-content-sha256" then
      kept[#kept + 1] = h
    end
  end
  return tostring(cred) .. " " .. table.concat(kept, ";")
end

local function body_text(ct, body)
  ct = string.lower(ct or "")
  body = body or ""
  if body == "" then
    return ""
  end
  if string.find(ct, "json", 1, true) then
    local v = json.decode(body)
    return v ~= nil and pt.canonical(v) or body
  elseif string.find(ct, "x-www-form-urlencoded", 1, true) then
    local list = {}
    for pair in string.gmatch(body, "[^&]+") do
      list[#list + 1] = pct_decode(pair)
    end
    table.sort(list)
    return table.concat(list, "&")
  elseif string.find(ct, "xml", 1, true) then
    return pt.canonical_xml(body, true)
  end
  return body
end

-- Lua values in the reference's form: blobs as { $bytes }, secrets unwrapped
local function plain(v, depth)
  depth = depth or 0
  v = secret.unwrap(v)
  if type(v) ~= "table" or v == json.null or depth > 40 then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = plain(x, depth + 1)
  end
  if json.is_array(v) then
    return json.array(out)
  end
  return out
end

local function method_for(service, op_name)
  for key, op in pairs(service.ops or {}) do
    if type(op) == "table" and op.name == op_name then
      return key, op
    end
  end
  return nil
end

-- blob members: the reference has { $bytes = text }; the Lua value is the text
local function unbytes(v, depth)
  depth = depth or 0
  if type(v) ~= "table" or v == json.null or depth > 40 then
    return v
  end
  if v["$bytes"] ~= nil and next(v, next(v)) == nil then
    return v["$bytes"]
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = unbytes(x, depth + 1)
  end
  if json.is_array(v) then
    return json.array(out)
  end
  return out
end

-- case input -> Lua input: { $bytes } is a string, { $date } epoch seconds
local function to_input(v, depth)
  depth = depth or 0
  if type(v) ~= "table" or v == json.null or depth > 40 then
    return v
  end
  if v["$date"] ~= nil then
    return v["$date"]
  end
  if v["$bytes"] ~= nil then
    return v["$bytes"]
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = to_input(x, depth + 1)
  end
  if json.is_array(v) then
    return json.array(out)
  end
  return out
end

-- the fields of a TS error the Lua error should carry too (TS-only plumbing skipped)
local TS_ONLY = { retryAfter = true, ["$metadata"] = true, name = true }

function M.run_case(c)
  local module = "aws." .. string.gsub(c.service, "%-", "_")
  local ok, class = compat.pcall(require, module)
  if not ok then
    return nil, "require " .. module .. ": " .. tostring(class)
  end
  local service = require(module .. ".service")
  local method = method_for(service, c.op)
  if not method then
    return nil, module .. " has no operation " .. c.op
  end
  local res = c.response or { status = 200, headers = {}, body = "" }
  local host = testing.host({ responses = { res } })
  local client = class.new({
    region = c.region or "us-east-1",
    credentials = aws_credentials.static({
      access_key_id = "AKIDEXAMPLE",
      secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    }),
    host = host,
    retry = "none",
  })
  local value, err = client[method](client, to_input(c.input or json.object({})))
  local out = { request = host.requests[1] }
  if value ~= nil then
    out.outcome = { ok = plain(value) }
  else
    out.outcome = { error = err }
  end
  return out
end

local function compare(c, ref, got)
  local problems = {}
  local function check(what, a, b)
    if a ~= b then
      problems[#problems + 1] = what
        .. "\n    lua:  "
        .. tostring(a)
        .. "\n    ts:   "
        .. tostring(b)
    end
  end
  local req, rreq = got.request, ref.request
  if rreq and not req then
    problems[#problems + 1] = "no request sent (" .. pt.canonical(got.outcome) .. ")"
  elseif rreq then
    check("method", req.method, rreq.method)
    check("url", base_url(req.url), base_url(rreq.url))
    check("query", query_pairs(req.url), query_pairs(rreq.url, rreq.params))
    local lh = {}
    for k, v in pairs(req.headers or {}) do
      lh[string.lower(k)] = v
    end
    for k, v in pairs(rreq.headers or {}) do
      if not VOLATILE[k] then
        check("header " .. k, lh[k], v)
      end
    end
    for k, v in pairs(lh) do
      if not VOLATILE[k] and rreq.headers[k] == nil then
        check("header " .. k, v, nil)
      end
    end
    check("signing scope", auth_scope(lh.authorization), auth_scope(rreq.headers.authorization))
    check(
      "body",
      body_text(lh["content-type"], req.body),
      body_text(rreq.headers["content-type"], rreq.body)
    )
  end
  local o, ro = got.outcome, ref.outcome
  if ro.ok ~= nil then
    if o.ok == nil then
      check("outcome", "error " .. tostring(o.error.tag) .. ": " .. tostring(o.error.message), "ok")
    else
      check("value", pt.canonical(o.ok), pt.canonical(unbytes(ro.ok)))
    end
  elseif ro.error ~= nil then
    if o.error == nil then
      check("outcome", "ok " .. pt.canonical(o.ok), "error " .. ro.error.tag)
    else
      local e = o.error
      check("error tag", e.tag, ro.error.tag)
      check("error message", e.message, ro.error.message)
      for k, v in pairs(ro.error.fields or {}) do
        if not TS_ONLY[k] then
          check("error field " .. k, pt.canonical(plain(e[k])), pt.canonical(unbytes(v)))
        end
      end
    end
  else
    problems[#problems + 1] = "Distilled raised a defect: " .. tostring(ro.defect)
  end
  return problems
end

--- M.run(root) -> passed, failed, lines
function M.run(dir)
  local cases = json.decode(read(dir .. "/verify/conform/cases/aws.json"))
  local refs = json.decode(read(dir .. "/verify/conform/ref/aws/outcomes.json"))
  local by_id = {}
  for _, r in ipairs(refs) do
    by_id[r.id] = r
  end
  local passed, failed, lines = 0, 0, {}
  for _, c in ipairs(cases) do
    local ref = by_id[c.id]
    local problems
    if not ref then
      problems = { "no reference: run dl conform aws with Node" }
    else
      local got, err = M.run_case(c)
      problems = got and compare(c, ref, got) or { tostring(err) }
    end
    if #problems == 0 then
      passed = passed + 1
    else
      failed = failed + 1
      lines[#lines + 1] = "FAIL " .. c.id .. "\n  " .. table.concat(problems, "\n  ")
    end
  end
  return passed, failed, lines
end

if rex_api or (arg and arg[0] and string.find(arg[0], "aws_compare%.lua$")) then
  local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
  local passed, failed, lines = M.run(root)
  for _, l in ipairs(lines) do
    print(l)
  end
  print(string.format("conform aws [%s]: %d passed, %d failed", runtime, passed, failed))
  if failed > 0 then
    if rex_api then
      error("conform aws: " .. failed .. " failed")
    end
    os.exit(1)
  end
  if rex_api then
    -- a rex do script's return value is printed as JSON
    return { passed = passed, failed = failed }
  end
end

return M
