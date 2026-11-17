-- Tencent Cloud conformance: the generated clients (clients/tencentcloud) against what
-- Distilled's TypeScript SDK did, saved in spec/golden/tencentcloud/ref.json by
-- verify/lib/tencentcloud_ref.mjs (`verify/dl tencentcloud-ref`). Runs in every runtime.
--
-- Compared: TC3 signer vectors (every output field); for each request case the method,
-- URL, Authorization, X-TC-* headers, Content-Type and the body bytes; for each response
-- case the outcome (the value, or the error's tag, categories, retryable, throttling,
-- and every field Distilled's error has). Intended differences (verify/features/
-- tencentcloud.md): a parse error's message says what failed (Distilled: ""); Lua errors
-- carry `status` (and ServiceUnavailable from an envelope its `code` and `request_id`),
-- which Distilled's classes do not have.
local t = require("spec.harness")
local json = require("distilled.json")
local signer = require("distilled.tencentcloud.signer")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local text = read(t.root .. "/spec/golden/tencentcloud/ref.json")
local ref = text and json.decode(text)

local function enc(v)
  return (json.encode(v))
end

local function client(c)
  local Class = require("tencentcloud." .. c.product)
  local creds = c.creds or {}
  local host = testing.host({
    epoch = ref.epoch,
    responses = {
      c.response and {
        status = c.response.status or 200,
        headers = c.response.headers,
        body = c.response.body,
      } or { status = 200, body = '{"Response":{"RequestId":"req-ok"}}' },
    },
  })
  local opts = {
    host = host,
    retry = "none",
    secret_id = ref.secret_id,
    secret_key = ref.secret_key,
    region = creds.region,
    root_domain = creds.root_domain,
    validation = c.validation,
  }
  if creds.session_token then
    opts.session_token = ref.session_token
  end
  return Class.new(opts), host
end

-- the Lua error as the Node script views a Distilled error
local ALLOWED_EXTRA = { status = true, code = true, request_id = true }
local function error_matches(lua_err, want)
  local cats = {}
  for k in pairs(lua_err.categories or {}) do
    cats[#cats + 1] = k
  end
  table.sort(cats)
  local got = {
    tag = lua_err.tag,
    categories = json.array(cats),
    retryable = lua_err.retryable == true,
    throttling = lua_err.throttling == true,
    status = lua_err.status,
    code = lua_err.code,
    message = lua_err.message,
    request_id = lua_err.request_id,
    retry_after = lua_err.retry_after,
    body = lua_err.body,
  }
  local problems = {}
  for _, k in ipairs({ "tag", "categories", "retryable", "throttling" }) do
    if enc(got[k]) ~= enc(want[k]) then
      problems[#problems + 1] = k .. ": lua " .. enc(got[k]) .. " | distilled " .. enc(want[k])
    end
  end
  for _, k in ipairs({ "status", "code", "message", "request_id", "retry_after", "body" }) do
    local w = want[k]
    if w == nil then
      if
        got[k] ~= nil
        and not ALLOWED_EXTRA[k]
        and not (k == "body" and got.tag == "TencentCloudParseError")
      then
        problems[#problems + 1] = k .. ": lua has " .. enc(got[k]) .. ", distilled none"
      end
    elseif k == "message" and want.tag == "TencentCloudParseError" then
      -- intended: Distilled's parse error message is "", ours names the failure
      if type(got.message) ~= "string" or got.message == "" then
        problems[#problems + 1] = "message: lua has no message"
      end
    elseif enc(got[k]) ~= enc(w) then
      problems[#problems + 1] = k .. ": lua " .. enc(got[k]) .. " | distilled " .. enc(w)
    end
  end
  return #problems == 0, table.concat(problems, "; ")
end

t.describe("tencentcloud conformance: TC3 signer vectors from Distilled", function()
  if not ref then
    t.pending("no spec/golden/tencentcloud/ref.json (run verify/dl tencentcloud-ref)")
    return
  end
  for _, v in ipairs(ref.signer) do
    t.it(v.name, function()
      local i = v.input
      local s = signer.sign({
        secret_id = i.secret_id,
        secret_key = i.secret_key,
        service = i.service,
        host = i.host,
        action = i.action,
        timestamp = i.timestamp,
        content_type = i.content_type,
        payload = i.payload,
        signed_headers = i.signed_headers,
      })
      for _, k in ipairs({ "canonical_request", "string_to_sign", "credential_scope", "signature" }) do
        t.eq(s[k], v.out[k], k)
      end
      t.eq(s.authorization, v.out.authorization)
    end)
  end
end)

t.describe("tencentcloud conformance: requests match Distilled's byte for byte", function()
  if not ref then
    t.pending("no spec/golden/tencentcloud/ref.json")
    return
  end
  for _, c in ipairs(ref.requests) do
    t.it(c.id .. " (" .. c.product .. "." .. c.method .. ")", function()
      local cl, host = client(c)
      local _, err = cl[c.method](cl, c.input)
      t.eq(err, nil, "call")
      local got, want = host.requests[1], c.request
      t.eq(got.method, want.method)
      t.eq(got.url, want.url)
      t.eq(got.body, want.body, "body")
      for name, value in pairs(want.headers) do
        if name ~= "content-length" then
          t.eq(got.headers[name], value, name)
        end
      end
      for name in pairs(got.headers) do
        if string.find(name, "^x%-tc%-") then
          t.truthy(want.headers[name] ~= nil, "lua sends " .. name .. ", distilled does not")
        end
      end
    end)
  end
end)

t.describe("tencentcloud conformance: responses decode as Distilled's do", function()
  if not ref then
    t.pending("no spec/golden/tencentcloud/ref.json")
    return
  end
  for _, c in ipairs(ref.responses) do
    t.it(c.id, function()
      local cl = client(c)
      local value, err = cl[c.method](cl, c.input)
      if c.outcome.ok then
        t.eq(err, nil, "error")
        t.eq(enc(value), enc(c.outcome.value), "value")
      else
        t.truthy(err ~= nil, "expected " .. tostring(c.outcome.error.tag))
        local ok, why = error_matches(err, c.outcome.error)
        t.truthy(ok, why)
      end
    end)
  end
end)
