-- Coinbase and Polymarket conformance: clients/coinbase and clients/polymarket against
-- Distilled's packages on the cases in spec/golden/signed_rest/conform.lua (written by
-- verify/lib/signed_rest_conform.mjs, `verify/dl signed-rest-vectors`):
--   - Coinbase: every request's method, URL, headers and body, and its CDP JWT: the
--     protected header and the claims byte for byte; the EdDSA signature byte for byte
--     (Ed25519 is deterministic); the ES256 signature verified with the key's public
--     half (node:crypto's ES256 signatures are randomized, ours are RFC 6979). The
--     nonce is the same 16 bytes on both sides (host.random scripted here,
--     crypto.randomBytes stubbed there). The outcome of canned failures (errorType and
--     status dispatch, isValid/success bodies).
--   - Polymarket: the L2-signed requests (POLY_* headers), unsigned requests, relayer and
--     Perps headers, and the outcome of canned failures.
-- Intended differences are in INTENDED, each with its reason.
local t = require("spec.harness")
local json = require("distilled.json")
local testing = require("distilled.testing")
local V = require("spec.golden.signed_rest.conform")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Coinbase = require("coinbase")
local Polymarket = require("polymarket")

-- headers the Lua protocol adds itself (Distilled's HttpClient adds its own later)
local IGNORED_HEADERS = { ["user-agent"] = true, ["accept"] = true, ["content-length"] = true }

-- Intended differences that hold for every case (each checked where it applies):
-- - JSON bodies: distilled.json writes object keys sorted, Distilled in schema order, so
--   bodies are compared as parsed JSON. Polymarket's L2 signature covers the exact body,
--   so where the bytes differ the golden file has Distilled's signL2 over the body as Lua
--   writes it (`sorted_body`), and the Lua body and signature must equal that.
-- - A Coinbase errorType class has no message in Distilled (errorMessage is a field);
--   here its message is errorMessage ("A message Rex shows must say something").
local INTENDED = {
  -- node:crypto's error text is part of Distilled's message after the ": "; ours names
  -- the format (distilled.crypto.pem): only the part before it is compared
  ["bad-pem"] = "message prefix",
  ["ed25519-pem-cannot-sign-es256"] = "message prefix",
  -- a failure body that is JSON but not the envelope: the message is the body
  -- re-serialized, with sorted keys here (JSON.stringify keeps the wire order)
  ["error-bad-envelope-types"] = "message json",
}

-- `{ n = 0 }` -> {}
local function normalize(v)
  if type(v) ~= "table" then
    return v
  end
  if v.n == 0 and next(v) == "n" and next(v, "n") == nil then
    return {}
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = normalize(x)
  end
  return out
end

local function plain(v)
  if type(v) ~= "table" then
    return v
  end
  if v == json.null then
    return nil
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = plain(x)
  end
  return out
end

local function snake(s)
  s = string.gsub(s, "(%l)(%u)", "%1_%2")
  s = string.gsub(s, "(%d)(%u)", "%1_%2")
  return string.lower(s)
end

-- host.random that yields `bytes` in order (each as (b + 0.5) / 256), then 0.5
local function scripted_random(bytes)
  local i = 0
  return function()
    i = i + 1
    local b = bytes[i]
    if b == nil then
      return 0.5
    end
    return (b + 0.5) / 256
  end
end

local function sorted(set)
  local list = {}
  for k in pairs(set or {}) do
    list[#list + 1] = k
  end
  table.sort(list)
  return list
end

local function check_error(err, want, id)
  t.truthy(err, id .. ": an error")
  if not err then
    return
  end
  t.eq(err.tag, want.tag, id .. " tag")
  if INTENDED[id] == "message prefix" then
    local prefix = string.match(want.message, "^(.-): ")
    t.eq(string.sub(err.message, 1, #prefix + 2), prefix .. ": ", id .. " message prefix")
  elseif INTENDED[id] == "message json" then
    t.same(plain(json.decode(err.message)), plain(json.decode(want.message)), id .. " message")
  elseif
    (want.message == nil or want.message == "")
    and want.fields
    and want.fields.errorMessage ~= nil
  then
    t.eq(err.message, want.fields.errorMessage, id .. " message (errorMessage)")
  elseif want.message == nil or want.message == "" then
    -- no message: Distilled's is undefined or "", distilled.errors gives "HTTP <status>"
    t.truthy(
      err.message == "" or err.message == err.tag or string.find(err.message, "^HTTP %d+$"),
      id .. " message: " .. tostring(err.message)
    )
  else
    t.eq(err.message, want.message, id .. " message")
  end
  t.same(sorted(err.categories), normalize(want.categories), id .. " categories")
  t.eq(err.retryable == true, want.retryable == true, id .. " retryable")
  for k, v in pairs(want.fields or {}) do
    t.eq(err[snake(k)], v, id .. " field " .. k)
  end
end

local function check_request(req, want, id, sorted_body)
  t.truthy(req, id .. ": a request was sent")
  if not req then
    return
  end
  t.eq(req.method, want.method, id .. " method")
  t.eq(req.url, want.url, id .. " url")
  local got = {}
  for k, v in pairs(req.headers or {}) do
    if not IGNORED_HEADERS[string.lower(k)] then
      got[string.lower(k)] = v
    end
  end
  got.authorization = nil
  local e = {}
  for k, v in pairs(want.headers) do
    if not IGNORED_HEADERS[k] then
      e[k] = v
    end
  end
  e.authorization = nil
  local body = req.body
  if body == "" then
    body = nil
  end
  if sorted_body then
    -- the bytes differ only in key order: the Lua body and its signature are Distilled's
    -- signL2 over the Lua body
    t.eq(body, sorted_body.body, id .. " body (sorted keys)")
    e.poly_signature = sorted_body.poly_signature
  end
  t.same(got, e, id .. " headers")
  if body ~= want.body and type(body) == "string" and type(want.body) == "string" then
    t.same(plain(json.decode(body)), plain(json.decode(want.body)), id .. " body (as JSON)")
  else
    t.eq(body, want.body, id .. " body")
  end
end

---------------------------------------------------------------------------------------
-- Coinbase
---------------------------------------------------------------------------------------

local CB = V.coinbase

local function coinbase(c, responses)
  local host = testing.host({ epoch = V.epoch, responses = responses })
  host.random = scripted_random(V.nonce_bytes)
  local client = Coinbase.new({
    host = host,
    retry = "none",
    api_key_id = c.key_id or CB.key_id,
    api_key_secret = c.secret or CB.secrets[c.key],
    base_url = c.base_url,
  })
  return client, host
end

t.describe("coinbase conformance: requests and the CDP JWT", function()
  local jws = require("distilled.crypto.jws")
  local pem = require("distilled.crypto.pem")
  for _, c in ipairs(CB.requests) do
    t.it(c.id, function()
      local client, host = coinbase(c, { { status = 200, body = {} } })
      local _, err = client[c.op](client, normalize(c.input))
      local want = c.expected
      if not want.ok then
        check_error(err, want.error, c.id)
        t.eq(#host.requests, 0, "nothing sent")
        return
      end
      local req = host.requests[1]
      check_request(req, want.request, c.id)
      local token = string.match(req.headers.authorization or "", "^Bearer (.+)$")
      t.truthy(token, "a bearer token")
      local h, p, s = string.match(token, "^([^.]+)%.([^.]+)%.([^.]+)$")
      t.eq(h, want.jwt.protected, c.id .. " JWT header")
      t.eq(p, want.jwt.payload, c.id .. " JWT claims")
      if want.jwt.alg == "EdDSA" then
        t.eq(s, want.jwt.signature, c.id .. " EdDSA signature")
      else
        local public = assert(pem.public_key(CB.ec_spki))
        local sig = assert(jws.b64_decode(s))
        t.truthy(jws.verify_bytes("ES256", public, h .. "." .. p, sig), c.id .. " ES256 verifies")
      end
    end)
  end
end)

t.describe("coinbase conformance: responses", function()
  for _, c in ipairs(CB.responses) do
    t.it(c.id, function()
      local client = coinbase({ key = "ed25519" }, { c.reply })
      local value, err = client[c.op](client, normalize(c.input))
      local want = c.expected
      if want.ok then
        t.eq(err, nil, c.id .. ": " .. tostring(err and (err.tag .. " " .. tostring(err.message))))
        t.same(plain(value), normalize(want.value), c.id)
      else
        t.eq(value, nil, c.id .. ": no value")
        check_error(err, want.error, c.id)
      end
    end)
  end
end)

---------------------------------------------------------------------------------------
-- Polymarket
---------------------------------------------------------------------------------------

local PM = V.polymarket

local function polymarket(c, responses)
  local host = testing.host({ epoch = V.epoch, responses = responses })
  local o = { host = host, retry = "none" }
  if c.clob then
    o.clob_address = PM.clob.address
    o.clob_api_key = PM.clob.apiKey
    o.clob_secret = c.clob_secret or PM.clob.secret
    o.clob_passphrase = PM.clob.passphrase
  end
  if c.relayer then
    o.relayer_address = PM.relayer.address
    o.relayer_api_key = PM.relayer.apiKey
  end
  if c.perps then
    o.perps_proxy = PM.perps.proxy
    o.perps_secret = PM.perps.secret
  end
  if c.base_urls then
    o.base_url = c.base_urls[c.model]
  end
  return Polymarket[c.model].new(o), host
end

t.describe("polymarket conformance: requests (L2 signing, relayer and Perps headers)", function()
  for _, c in ipairs(PM.requests) do
    t.it(c.id, function()
      local client, host = polymarket(c, { { status = 200, body = {} } })
      local _, err = client[c.op](client, normalize(c.input))
      local want = c.expected
      if not want.ok then
        check_error(err, want.error, c.id)
        return
      end
      check_request(host.requests[1], want.request, c.id, want.sorted_body)
    end)
  end
end)

t.describe("polymarket conformance: responses", function()
  for _, c in ipairs(PM.responses) do
    t.it(c.id, function()
      local client = polymarket(c, { c.reply })
      local value, err = client[c.op](client, normalize(c.input))
      local want = c.expected
      if want.ok then
        t.eq(err, nil, c.id .. ": " .. tostring(err and (err.tag .. " " .. tostring(err.message))))
        t.same(plain(value), normalize(want.value), c.id)
      else
        t.eq(value, nil, c.id .. ": no value")
        check_error(err, want.error, c.id)
      end
    end)
  end
end)
