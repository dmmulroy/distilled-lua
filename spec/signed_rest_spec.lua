-- Coinbase's CDP JWT and Polymarket's L1/L2 auth through the generated clients
-- (clients/coinbase, clients/polymarket) and their glue (providers/glue/coinbase.lua,
-- polymarket.lua, polymarket_clob.lua): byte-exact L1 headers against Polymarket's own
-- clob-client (spec/golden/signed_rest/l1.lua), the official L2 vector, credentials
-- from the environment, missing and broken credentials, fresh nonces and timestamps per
-- attempt, and that secrets stay out of errors. Differential cases against Distilled
-- are in signed_rest_conform_spec.lua. No network.
local t = require("spec.harness")
local json = require("distilled.json")
local testing = require("distilled.testing")
local L1 = require("spec.golden.signed_rest.l1")
local V = require("spec.golden.signed_rest.conform")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Coinbase = require("coinbase")
local Polymarket = require("polymarket")
local clob_glue = require("polymarket.clob.glue")

local ED_SECRET = V.coinbase.secrets.ed25519
local EC_PEM = V.coinbase.secrets.es256

local function host_with(responses, env)
  return testing.host({ epoch = 1700000000, responses = responses or {}, env = env or {} })
end

local function jwt_parts(req)
  local token = string.match(req.headers.authorization or "", "^Bearer (.+)$")
  local jws = require("distilled.crypto.jws")
  local h, p = string.match(token or "", "^([^.]+)%.([^.]+)%.")
  return json.decode(jws.b64_decode(h)), json.decode(jws.b64_decode(p))
end

---------------------------------------------------------------------------------------
-- Polymarket L1 and L2
---------------------------------------------------------------------------------------

t.describe("polymarket L1: EIP-712 ClobAuth headers equal clob-client createL1Headers", function()
  t.it("all " .. #L1 .. " vectors (5 keys, chains 137 and 80002, nonces 0 to 2^256-1)", function()
    for i, v in ipairs(L1) do
      local h, err = clob_glue.l1_headers({
        private_key = v.private_key,
        chain_id = v.chain_id,
        nonce = v.nonce,
        timestamp = v.timestamp,
      })
      t.eq(err, nil, "vector " .. i)
      t.eq(h.poly_address, v.poly_address, "vector " .. i .. " address")
      t.eq(h.poly_signature, v.poly_signature, "vector " .. i .. " signature")
      t.eq(h.poly_timestamp, v.poly_timestamp, "vector " .. i .. " timestamp")
      t.eq(h.poly_nonce, v.poly_nonce, "vector " .. i .. " nonce")
    end
  end)

  t.it("create_api_key and derive_api_key carry L1 headers, not L2, with l1_private_key", function()
    local v = L1[2] -- chain 137, nonce 7
    local host = host_with({ { status = 200, body = {} }, { status = 200, body = {} } })
    host.clock.epoch0 = v.timestamp
    local c = Polymarket.clob.new({
      host = host,
      retry = "none",
      l1_private_key = v.private_key,
      l1_nonce = v.nonce,
      clob_address = "0x1111111111111111111111111111111111111111",
      clob_api_key = "k",
      clob_secret = "AAAA",
      clob_passphrase = "p",
    })
    t.eq(select(2, c:create_api_key({})), nil)
    t.eq(select(2, c:derive_api_key({})), nil)
    for i, method in ipairs({ "POST", "GET" }) do
      local req = host.requests[i]
      t.eq(req.method, method)
      t.eq(req.headers.poly_address, v.poly_address)
      t.eq(req.headers.poly_signature, v.poly_signature)
      t.eq(req.headers.poly_timestamp, v.poly_timestamp)
      t.eq(req.headers.poly_nonce, v.poly_nonce)
      t.eq(req.headers.poly_api_key, nil, "no L2 headers")
      t.eq(req.headers.poly_passphrase, nil)
    end
  end)

  t.it("POLY_PRIVATE_KEY and POLY_CHAIN_ID from the environment", function()
    local v = L1[5] -- chain 80002, nonce 0
    local host = host_with({ { status = 200, body = {} } }, {
      POLY_PRIVATE_KEY = v.private_key,
      POLY_CHAIN_ID = v.chain_id,
    })
    host.clock.epoch0 = v.timestamp
    local c = Polymarket.clob.new({ host = host, retry = "none" })
    t.eq(select(2, c:derive_api_key({})), nil)
    t.eq(host.requests[1].headers.poly_signature, v.poly_signature)
  end)

  t.it("other operations are never L1-signed", function()
    local host = host_with({ { status = 200, body = {} } })
    local c =
      Polymarket.clob.new({ host = host, retry = "none", l1_private_key = L1[1].private_key })
    t.eq(select(2, c:get_orders({})), nil)
    t.eq(host.requests[1].headers.poly_signature, nil)
  end)

  t.it("a bad key, chain id or nonce is a ConfigError that does not hold the key", function()
    local bad = "0x" .. string.rep("zz", 32)
    for _, case in ipairs({
      { opts = { l1_private_key = bad }, key = "l1_private_key" },
      { opts = { l1_private_key = "0x" .. string.rep("ff", 32) }, key = "l1_private_key" },
      { opts = { l1_private_key = L1[1].private_key, l1_nonce = "-1" } },
      { opts = { l1_private_key = L1[1].private_key, chain_id = "1e3" } },
      {
        opts = { l1_private_key = L1[1].private_key, l1_nonce = "1" .. string.rep("0", 80) },
      },
    }) do
      local host = host_with({})
      case.opts.host = host
      case.opts.retry = "none"
      local c = Polymarket.clob.new(case.opts)
      local value, err = c:create_api_key({})
      t.eq(value, nil)
      t.eq(err and err.tag, "ConfigError")
      if case.key then
        t.eq(err.key, case.key)
      end
      t.no_match(tostring(err.message), string.sub(L1[1].private_key, 3), true)
      t.eq(#host.requests, 0, "nothing sent")
    end
  end)
end)

t.describe("polymarket L2: POLY_* headers", function()
  -- Polymarket/clob-client tests/signing/hmac.test.ts and py-clob-client test_hmac.py
  t.it("the official clients' vector", function()
    t.eq(
      clob_glue.sign_l2({
        secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        timestamp = 1000000,
        method = "test-sign",
        request_path = "/orders",
        body = '{"hash": "0x123"}',
      }),
      "ZwAdJKvoYRlEKDkNMwd5BuwNNtg93kNaR_oU2HrfVvc="
    )
  end)

  t.it("a base64url secret without padding reads as base64", function()
    local function sign(secret)
      return clob_glue.sign_l2({
        secret = secret,
        timestamp = 1000000,
        method = "test-sign",
        request_path = "/orders",
        body = '{"hash": "0x123"}',
      })
    end
    t.eq(
      sign("--_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
      sign("++/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    )
  end)

  t.it("the CLOB group from the environment signs; each retry attempt is re-signed", function()
    local host = host_with({
      { status = 429, headers = { ["retry-after"] = "2" }, body = { error = "slow" } },
      { status = 200, body = {} },
    }, {
      POLY_ADDRESS = "0xabc",
      CLOB_API_KEY = "key",
      CLOB_SECRET = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      CLOB_PASS_PHRASE = "pass",
    })
    local c = Polymarket.clob.new({ host = host })
    local _, err = c:get_orders({ market = "m" })
    t.eq(err, nil)
    t.eq(#host.requests, 2, "one retry")
    local a, b = host.requests[1].headers, host.requests[2].headers
    t.eq(a.poly_address, "0xabc")
    t.truthy(tonumber(b.poly_timestamp) > tonumber(a.poly_timestamp), "a later timestamp")
    t.ne(a.poly_signature, b.poly_signature, "signed again")
    t.eq(
      b.poly_signature,
      clob_glue.sign_l2({
        secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        timestamp = b.poly_timestamp,
        method = "GET",
        request_path = "/data/orders",
      })
    )
  end)

  t.it("CLOB_API_URL moves the CLOB host; the signed path is below it", function()
    local host = host_with({ { status = 200, body = {} } }, {
      CLOB_API_URL = "http://localhost:9000/proxy",
      POLY_ADDRESS = "0xabc",
      CLOB_API_KEY = "key",
      CLOB_SECRET = "AAAA",
      CLOB_PASS_PHRASE = "pass",
    })
    local c = Polymarket.clob.new({ host = host, retry = "none" })
    t.eq(select(2, c:get_orders({})), nil)
    local req = host.requests[1]
    t.eq(req.url, "http://localhost:9000/proxy/data/orders")
    t.eq(
      req.headers.poly_signature,
      clob_glue.sign_l2({
        secret = "AAAA",
        timestamp = req.headers.poly_timestamp,
        method = "GET",
        request_path = "/data/orders",
      })
    )
  end)

  t.it("an incomplete group is a ConfigError naming the missing variables, in every API", function()
    for _, model in ipairs(Polymarket.services) do
      local host = host_with({}, { POLY_ADDRESS = "0xabc", CLOB_SECRET = "s3cr3t-value" })
      local c = Polymarket[model].new({ host = host, retry = "none" })
      -- the first operation by name: the settings are read before the input
      local names = {}
      for k in pairs(require("polymarket." .. model .. ".service").ops) do
        names[#names + 1] = k
      end
      table.sort(names)
      local _, err = c[names[1]](c, {})
      t.eq(err and err.tag, "ConfigError", model)
      t.eq(
        err.message,
        "Polymarket CLOB credentials are incomplete: set CLOB_API_KEY, CLOB_PASS_PHRASE",
        model
      )
      t.eq(err.key, "CLOB_API_KEY")
      t.no_match(err.message, "s3cr3t", true)
      t.eq(#host.requests, 0)
    end
    local _, err = Polymarket.relayer
      .new({ host = host_with({}), retry = "none", relayer_api_key = "k" })
      :get_nonce({ address = "0x1", type = "SAFE" })
    t.eq(err.message, "Polymarket relayer credentials are incomplete: set RELAYER_API_KEY_ADDRESS")
    _, err = Polymarket.perps
      .new({ host = host_with({}), retry = "none", perps_proxy = "0x1" })
      :get_config({})
    t.eq(err.message, "Polymarket Perps credentials are incomplete: set POLYMARKET_SECRET")
  end)
end)

---------------------------------------------------------------------------------------
-- Coinbase
---------------------------------------------------------------------------------------

t.describe("coinbase: the CDP JWT", function()
  t.it("CDP_API_KEY_NAME stands in for CDP_API_KEY_ID; claims follow host.epoch", function()
    local host = host_with({ { status = 200, body = { accounts = {} } } }, {
      CDP_API_KEY_NAME = "organizations/o/apiKeys/k",
      CDP_API_KEY_SECRET = ED_SECRET,
    })
    local c = Coinbase.new({ host = host, retry = "none" })
    t.eq(select(2, c:list_evm_accounts({ pageSize = 2 })), nil)
    local header, claims = jwt_parts(host.requests[1])
    t.eq(header.alg, "EdDSA")
    t.eq(header.kid, "organizations/o/apiKeys/k")
    t.eq(claims.sub, "organizations/o/apiKeys/k")
    t.eq(claims.nbf, 1700000000)
    t.eq(claims.exp, 1700000120)
    t.eq(claims.uri, "GET api.cdp.coinbase.com/platform/v2/evm/accounts")
    t.match(header.nonce, "^%x+$")
    t.eq(#header.nonce, 32)
  end)

  t.it("each attempt mints a new token (nonce and nbf) when a 429 is retried", function()
    local host = host_with({
      {
        status = 429,
        headers = { ["retry-after"] = "2" },
        body = { errorType = "rate_limit_exceeded", errorMessage = "slow" },
      },
      { status = 200, body = { accounts = {} } },
    })
    local c = Coinbase.new({ host = host, api_key_id = "id", api_key_secret = EC_PEM })
    t.eq(select(2, c:list_evm_accounts({})), nil)
    t.eq(#host.requests, 2)
    local h1, c1 = jwt_parts(host.requests[1])
    local h2, c2 = jwt_parts(host.requests[2])
    t.eq(h1.alg, "ES256")
    t.ne(h1.nonce, h2.nonce, "a fresh nonce")
    t.truthy(c2.nbf >= c1.nbf + 2, "nbf after the wait")
  end)

  t.it("missing credentials are ConfigErrors before anything is sent", function()
    local host = host_with({})
    local _, err = Coinbase.new({ host = host, retry = "none", api_key_id = "id" })
      :list_evm_accounts({})
    t.eq(err.tag, "ConfigError")
    t.eq(err.message, "CDP_API_KEY_SECRET environment variable is required")
    _, err = Coinbase.new({ host = host, retry = "none", api_key_secret = ED_SECRET })
      :list_evm_accounts({})
    t.eq(err.message, "CDP_API_KEY_ID (or CDP_API_KEY_NAME) environment variable is required")
    t.eq(#host.requests, 0)
  end)

  t.it("a broken secret never appears in the error", function()
    local secret = "-----BEGIN EC PRIVATE KEY-----\nTOPSECRETbytes\n-----END EC PRIVATE KEY-----\n"
    local _, err = Coinbase.new({
      host = host_with({}),
      retry = "none",
      api_key_id = "id",
      api_key_secret = secret,
    }):list_evm_accounts({})
    t.eq(err.tag, "ConfigError")
    t.no_match(tostring(err), "TOPSECRET", true)
    t.no_match(tostring(err.message), "TOPSECRET", true)
  end)

  t.it("an isValid failure body is the value; other failures are typed errors", function()
    local host = host_with({
      { status = 400, body = { isValid = false, reason = "policy" } },
      {
        status = 409,
        body = { errorType = "already_exists", errorMessage = "dup", correlationId = "c" },
      },
    })
    local c =
      Coinbase.new({ host = host, retry = "none", api_key_id = "id", api_key_secret = ED_SECRET })
    local v, err = c:get_evm_account({ address = "0x1" })
    t.eq(err, nil)
    t.eq(v.isValid, false)
    t.eq(v.reason, "policy")
    v, err = c:get_evm_account({ address = "0x1" })
    t.eq(v, nil)
    t.eq(err.tag, "AlreadyExists")
    t.truthy(err.categories.AlreadyExistsError)
    t.eq(err.error_type, "already_exists")
    t.eq(err.correlation_id, "c")
    t.eq(err.code, "already_exists")
  end)
end)

t.describe(
  "provider spec headers: names with underscores (Polymarket's RELAYER_API_KEY)",
  function()
    t.it("are valid; other symbols are not", function()
      local provider = require("distilled.gen.provider")
      local fx = require("verify.lib.gen_fixture")
      local spec, err = provider.validate(fx.provider({
        options = { relayer_key = { secret = true } },
        headers = { RELAYER_API_KEY = "{relayer_key}", ["x.y"] = "v" },
      }))
      t.eq(err, nil)
      t.truthy(spec)
      spec, err = provider.validate(fx.provider({ headers = { ["bad header"] = "v" } }))
      t.eq(spec, nil)
      t.match(err, "not a header name", true)
      spec, err = provider.validate(fx.provider({ headers = { ["x:y"] = "v" } }))
      t.eq(spec, nil)
      t.match(err, "not a header name", true)
    end)
  end
)
