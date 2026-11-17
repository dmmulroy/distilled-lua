-- GCP conformance against Distilled (task 21): the cases of spec/fixtures/gcp/cases.json
-- (verify/lib/gcp_conform_cases.lua) through the generated gcp and google_workspace
-- clients, compared with what Distilled's TypeScript did with the same cases
-- (spec/golden/gcp/reference.json, verify/lib/gcp_conform.mjs). Runs in every runtime.
--
-- Compared: method, URL, headers (but accept, user-agent and content-length, which
-- Distilled's HttpClient adds when it sends) and the JSON body; decoded values; error
-- tag, categories, retryable, throttling, message, code, retry_after, body, details, and
-- the envelope's status (Distilled's typed errors call it `status`; Lua's `rpc_status`,
-- because `status` is the HTTP status). Intended differences, each checked as such:
-- - a matched error without an envelope code has code nil (Distilled: 0; STATUS 01);
-- - a parse error's message says what failed (Distilled's is empty).
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function read(path)
  local f = assert(io.open(t.root .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local CASES = json.decode(read("spec/fixtures/gcp/cases.json"))
local REF = json.decode(read("spec/golden/gcp/reference.json"))
local TOKEN = "conform-token-0123"

local function by_id(list)
  local out = {}
  for _, x in ipairs(list) do
    out[x.id] = x
  end
  return out
end

-- JSON text with sorted keys: equal values give equal text
local function canon(v)
  if v == nil then
    return "nil"
  end
  return assert(json.encode(v))
end

local function module_of(c)
  return c.pkg .. (c.unstable and ".unstable." or ".") .. c.service
end

local function client_for(c, host)
  local Class = require(module_of(c))
  local o = c.options or {}
  local opts = { host = host, retry = "none", access_token = secret(TOKEN) }
  if c.pkg == "gcp" then
    opts.quota_project = o.quota_project
    opts.endpoint = o.endpoint
    opts.regional_endpoints = o.regional_endpoints
  end
  if c.validation then
    opts.validation = c.validation
  end
  return Class.new(opts)
end

local SENT_ONLY = { accept = true, ["user-agent"] = true, ["content-length"] = true }

local function headers_of(h)
  local out = {}
  for k, v in pairs(h or {}) do
    if not SENT_ONLY[string.lower(k)] then
      out[string.lower(k)] = v
    end
  end
  return out
end

local function body_of(text)
  if text == nil or text == json.null then
    return "nil"
  end
  local v = json.decode(text)
  return v ~= nil and canon(v) or text
end

local function set_of(list)
  local out = {}
  for _, k in ipairs(list or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return table.concat(out, ",")
end

local function categories_of(err)
  local out = {}
  for k in pairs(err.categories or {}) do
    out[#out + 1] = k
  end
  table.sort(out)
  return table.concat(out, ",")
end

-- compare a Lua error with Distilled's error view; returns a list of differences
local function error_diff(want, got)
  local d = {}
  local function chk(what, a, b)
    if a ~= b then
      d[#d + 1] = what .. ": distilled " .. tostring(a) .. ", lua " .. tostring(b)
    end
  end
  chk("tag", want.tag, got.tag)
  chk("categories", set_of(want.categories), categories_of(got))
  chk("retryable", want.retryable, got.retryable == true)
  -- Distilled's view reads the retryable annotation's throttling flag; Lua's
  -- err.throttling is isThrottling (also true for a non-retryable ThrottlingError)
  chk("throttling", want.throttling, got.retryable == true and got.throttling == true)
  if string.find(tostring(want.tag), "ParseError$") and want.message == "" then
    -- intended: the Lua parse error says what failed
    chk("parse message", true, type(got.message) == "string" and got.message ~= "")
  else
    chk("message", want.message, got.message)
  end
  if type(want.status) == "string" then
    chk("rpc_status", want.status, got.rpc_status)
  elseif want.status ~= nil then
    chk("status", want.status, got.status)
  end
  if want.code == 0 then
    chk("code (intended: nil for 0)", nil, got.code)
  elseif want.code ~= nil then
    chk("code", want.code, got.code)
  end
  if want.retry_after ~= nil then
    chk("retry_after", want.retry_after, got.retry_after)
  end
  if want.details ~= nil then
    chk("details", canon(want.details), canon(got.details))
  end
  if want.body ~= nil then
    chk("body", canon(want.body), canon(got.body))
  end
  return d
end

t.describe("gcp conformance: requests", function()
  local ref = by_id(REF.requests)
  t.it("has a Distilled reference for every case", function()
    t.eq(#REF.requests, #CASES.requests)
  end)
  t.it("builds every request as Distilled does", function()
    local problems, built = {}, 0
    for _, c in ipairs(CASES.requests) do
      local want = ref[c.id]
      local host = testing.host({ responses = { { status = 200, body = "{}" } } })
      local client = client_for(c, host)
      local _, err = client[c.op](client, c.input)
      local sent = host.requests[1]
      local d = {}
      if not want then
        d[1] = "no reference"
      elseif not want.ok then
        if sent ~= nil or not err or err.tag ~= want.error.tag then
          d[1] = "distilled failed with "
            .. tostring(want.error.tag)
            .. ", lua "
            .. (err and tostring(err.tag) or "built it")
        elseif err.message ~= want.error.message then
          d[1] = "message: " .. tostring(err.message)
        end
      elseif not sent then
        d[1] = "lua did not send: " .. tostring(err)
      else
        if sent.method ~= want.method then
          d[#d + 1] = "method " .. tostring(sent.method)
        end
        if sent.url ~= want.url then
          d[#d + 1] = "url\n    distilled " .. want.url .. "\n    lua       " .. sent.url
        end
        if canon(headers_of(sent.headers)) ~= canon(headers_of(want.headers)) then
          d[#d + 1] = "headers distilled "
            .. canon(headers_of(want.headers))
            .. " lua "
            .. canon(headers_of(sent.headers))
        end
        if body_of(sent.body) ~= body_of(want.body) then
          d[#d + 1] = "body distilled " .. body_of(want.body) .. " lua " .. body_of(sent.body)
        end
      end
      if #d > 0 then
        problems[#problems + 1] = c.id .. ": " .. table.concat(d, "; ")
      else
        built = built + 1
      end
    end
    if #problems > 0 then
      t.fail(
        #problems
          .. " requests differ:\n  "
          .. table.concat(problems, "\n  ", 1, math.min(#problems, 15))
      )
    end
    t.eq(built, #CASES.requests)
  end)
end)

t.describe("gcp conformance: responses", function()
  local ref = by_id(REF.responses)
  for _, c in ipairs(CASES.responses) do
    t.it(c.id, function()
      local want = assert(ref[c.id], "no reference")
      local host = testing.host({ responses = { c.response } })
      local client = client_for(c, host)
      local value, err = client[c.op](client, c.input)
      if want.ok then
        t.eq(err, nil)
        t.eq(canon(value), canon(want.value))
      else
        t.truthy(err ~= nil, "lua succeeded with " .. canon(value))
        local d = error_diff(want.error, err)
        if #d > 0 then
          t.fail(table.concat(d, "\n"))
        end
      end
    end)
  end
end)

t.describe("gcp conformance: pagination flows", function()
  local ref = by_id(REF.flows)
  for _, c in ipairs(CASES.flows) do
    t.it(c.id, function()
      local want = assert(ref[c.id], "no reference")
      local host = testing.host({ responses = c.responses })
      local client = client_for(c, host)
      local got = {}
      for v in client[c.op .. "_" .. c.kind](client, c.input) do
        got[#got + 1] = v
      end
      local urls = {}
      for i, r in ipairs(host.requests) do
        urls[i] = r.method .. " " .. r.url
      end
      t.eq(canon(urls), canon(want.urls))
      t.eq(canon(got), canon(want.value))
    end)
  end
end)
