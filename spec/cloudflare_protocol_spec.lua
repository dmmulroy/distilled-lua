-- distilled.protocol.cloudflare through the generated clients (clients/cloudflare/), over
-- the scripted transport. Ported from Distilled's packages/cloudflare/test/
-- protocol.test.ts case by case (same operations, bodies and expectations), with Lua
-- names: members stay as the wire spells them (account_id, supports_url_encoding), where
-- the TS surface camelCases them.
local t = require("spec.harness")
local json = require("distilled.json")
local paginate = require("distilled.paginate")
local testing = require("distilled.testing")
local cloudflare = require("distilled.protocol.cloudflare")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local KV = require("cloudflare.kv")
local Zones = require("cloudflare.zones")
local K2 = require("cloudflare.k2")
local Pipelines = require("cloudflare.pipelines")

local BASE = "https://api.cloudflare.com/client/v4"

local function envelope(result, extra)
  local t2 = {
    success = true,
    errors = json.array({}),
    messages = json.array({}),
    result = result == nil and json.null or result,
  }
  for k, v in pairs(extra or {}) do
    t2[k] = v
  end
  return json.encode(t2)
end

local function error_envelope(list)
  return json.encode({
    success = false,
    errors = json.array(list),
    messages = json.array({}),
    result = json.null,
  })
end

-- run(Class, method, input, reply [, opts]) -> value, err, requests
-- opts: client options; `env` for the host; api_token "cf-token" unless auth is given
local function run(Class, method, input, reply, opts)
  opts = opts or {}
  local host = testing.host({
    env = opts.env or {},
    responses = {
      { status = reply.status or 200, headers = reply.headers or {}, body = reply.body or "" },
    },
  })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  if o.api_token == nil and o.api_key == nil and o.email == nil and not opts.env then
    o.api_token = "cf-token"
  end
  local client = Class.new(o)
  local v, e = client[method](client, input)
  return v, e, host.requests
end

local ns = { account_id = "acc", namespace_id = "ns" }
local namespace = { id = "ns", title = "kv", supports_url_encoding = true }

local function with(a, b)
  local out = {}
  for k, v in pairs(a) do
    out[k] = v
  end
  for k, v in pairs(b) do
    out[k] = v
  end
  return out
end

t.describe("cloudflare request encoding", function()
  t.it("an API token sends a Bearer Authorization header to the default base URL", function()
    local _, err, reqs = run(KV, "get_namespace", ns, { body = envelope(namespace) })
    t.eq(err, nil)
    t.eq(#reqs, 1)
    t.eq(reqs[1].method, "GET")
    t.eq(reqs[1].url, BASE .. "/accounts/acc/storage/kv/namespaces/ns")
    t.eq(reqs[1].headers.authorization, "Bearer cf-token")
    t.eq(reqs[1].headers["x-auth-key"], nil)
  end)

  t.it("a global API key sends X-Auth-Key and X-Auth-Email instead", function()
    local _, err, reqs = run(
      KV,
      "get_namespace",
      ns,
      { body = envelope(namespace) },
      { api_key = "global-key", email = "ops@example.test" }
    )
    t.eq(err, nil)
    t.eq(reqs[1].headers["x-auth-key"], "global-key")
    t.eq(reqs[1].headers["x-auth-email"], "ops@example.test")
    t.eq(reqs[1].headers.authorization, nil)
  end)

  t.it("an OAuth access token (a function source) is sent as Bearer", function()
    local _, err, reqs = run(KV, "get_namespace", ns, { body = envelope(namespace) }, {
      api_token = function()
        return "oauth-access"
      end,
    })
    t.eq(err, nil)
    t.eq(reqs[1].headers.authorization, "Bearer oauth-access")
  end)

  t.it("credentials come from the environment when no option is given", function()
    local _, err, reqs = run(KV, "get_namespace", ns, { body = envelope(namespace) }, {
      env = { CLOUDFLARE_API_TOKEN = "env-token", CLOUDFLARE_API_BASE_URL = "https://cf.env/v4" },
    })
    t.eq(err, nil)
    t.eq(reqs[1].headers.authorization, "Bearer env-token")
    t.eq(reqs[1].url, "https://cf.env/v4/accounts/acc/storage/kv/namespaces/ns")
    local _, err2, reqs2 = run(KV, "get_namespace", ns, { body = envelope(namespace) }, {
      env = { CLOUDFLARE_API_KEY = "k", CLOUDFLARE_EMAIL = "e@x.test" },
    })
    t.eq(err2, nil)
    t.eq(reqs2[1].headers["x-auth-key"], "k")
  end)

  t.it("an empty CLOUDFLARE_API_TOKEN counts as unset", function()
    local _, err, reqs = run(KV, "get_namespace", ns, { body = envelope(namespace) }, {
      env = { CLOUDFLARE_API_TOKEN = "", CLOUDFLARE_API_KEY = "k", CLOUDFLARE_EMAIL = "e" },
    })
    t.eq(err, nil)
    t.eq(reqs[1].headers.authorization, nil)
    t.eq(reqs[1].headers["x-auth-key"], "k")
  end)

  t.it("missing credentials are a ConfigError naming the variables, before any request", function()
    local _, err, reqs = run(KV, "get_namespace", ns, { body = envelope(namespace) }, { env = {} })
    t.fails_with("ConfigError", nil, err)
    t.match(err.message, "CLOUDFLARE_API_TOKEN or CLOUDFLARE_API_KEY+CLOUDFLARE_EMAIL", true)
    t.eq(#reqs, 0)
    local _, e2 = run(KV, "get_namespace", ns, {}, { env = { CLOUDFLARE_API_KEY = "k" } })
    t.eq(
      e2.message,
      "CLOUDFLARE_EMAIL environment variable is required when using CLOUDFLARE_API_KEY"
    )
    local _, e3 = run(KV, "get_namespace", ns, {}, { env = { CLOUDFLARE_EMAIL = "e" } })
    t.eq(
      e3.message,
      "CLOUDFLARE_API_KEY environment variable is required when using CLOUDFLARE_EMAIL"
    )
    local _, e4 = run(KV, "get_namespace", ns, {}, { api_key = "k" })
    t.fails_with("ConfigError", nil, e4)
    t.eq(e4.key, "email")
  end)

  t.it("explicit options win over the environment", function()
    local _, err, reqs = run(
      KV,
      "get_namespace",
      ns,
      { body = envelope(namespace) },
      { api_key = "opt-key", email = "o@x.test", env = { CLOUDFLARE_API_TOKEN = "env-token" } }
    )
    t.eq(err, nil)
    t.eq(reqs[1].headers.authorization, nil)
    t.eq(reqs[1].headers["x-auth-key"], "opt-key")
  end)

  t.it("a custom base_url replaces the default host", function()
    local _, _, reqs = run(
      KV,
      "get_namespace",
      ns,
      { body = envelope(namespace) },
      { base_url = "https://cf.test/v4" }
    )
    t.eq(reqs[1].url, "https://cf.test/v4/accounts/acc/storage/kv/namespaces/ns")
  end)

  t.it("a JSON body carries declared members; unknown camelCase keys go snake_case", function()
    local _, err, reqs = run(KV, "create_namespace", {
      account_id = "acc",
      title = "kv",
      someNewField = 1,
      expirationTtl = 60,
    }, { body = envelope({ id = "ns", title = "kv" }) })
    t.eq(err, nil)
    t.eq(reqs[1].method, "POST")
    t.eq(reqs[1].url, BASE .. "/accounts/acc/storage/kv/namespaces")
    t.same(json.decode(reqs[1].body), { title = "kv", some_new_field = 1, expiration_ttl = 60 })
  end)

  t.it("query members use their wire names", function()
    local _, _, reqs = run(
      KV,
      "list_namespaces",
      { account_id = "acc", page = 2, per_page = 5 },
      { body = envelope(json.array({})) }
    )
    t.eq(paginate.query_param(reqs[1].url, "page"), "2")
    t.eq(paginate.query_param(reqs[1].url, "per_page"), "5")
  end)

  t.it("a member-supplied Authorization header is Bearer-prefixed and wins", function()
    local Workers = require("cloudflare.workers")
    local _, err, reqs = run(
      Workers,
      "create_asset_upload",
      { account_id = "acc", base64 = true, jwt_token = "session-jwt" },
      { body = envelope({ jwt = "done" }) }
    )
    t.eq(err, nil)
    t.eq(reqs[1].headers.authorization, "Bearer session-jwt")
    local _, _, reqs2 = run(
      Workers,
      "create_asset_upload",
      { account_id = "acc", base64 = true, jwt_token = "Bearer already" },
      { body = envelope({ jwt = "done" }) }
    )
    t.eq(reqs2[1].headers.authorization, "Bearer already")
  end)
end)

t.describe("cloudflare envelope unwrapping", function()
  t.it("struct outputs are read from `result`", function()
    local v = run(KV, "get_namespace", ns, { body = envelope(namespace) })
    t.same(v, namespace)
  end)

  t.it("a body without `result` is the payload itself", function()
    local v = run(KV, "get_namespace", ns, { body = json.encode(namespace) })
    t.same(v, namespace)
  end)

  t.it("a sole envelopePayload output returns `result` directly", function()
    local v = run(
      KV,
      "get_namespace_metadata",
      with(ns, { key_name = "k" }),
      { body = envelope({ owner = "me", tags = json.array({ "a" }) }) }
    )
    t.same(v, { owner = "me", tags = { "a" } })
  end)

  t.it("a paginated output maps `result` and keeps `result_info`", function()
    local v = run(KV, "list_namespaces", { account_id = "acc" }, {
      body = envelope(json.array({ namespace }), {
        result_info = { page = 1, per_page = 20, count = 1, total_count = 1 },
      }),
    })
    t.same(v, {
      result = { namespace },
      result_info = { page = 1, per_page = 20, count = 1, total_count = 1 },
    })
  end)

  t.it("a paginated output omits result_info when the envelope has none", function()
    local v = run(
      KV,
      "list_namespaces",
      { account_id = "acc" },
      { body = envelope(json.array({})) }
    )
    t.same(v, { result = {} })
  end)

  t.it("binary outputs return the raw body and project typed headers", function()
    local v = run(KV, "get_namespace_value", with(ns, { key_name = "k" }), {
      body = "raw-bytes",
      headers = { ["content-type"] = "application/octet-stream", expiration = "1700000000" },
    })
    t.eq(v.expiration, 1700000000)
    t.eq(v.content_type, "application/octet-stream")
    t.eq(v.body, "raw-bytes")
  end)

  t.it("binary outputs still decode error statuses through the envelope", function()
    local _, err = run(KV, "get_namespace_value", with(ns, { key_name = "k" }), {
      status = 404,
      body = error_envelope({ { code = 10009, message = "get: 'key not found'" } }),
    })
    t.fails_with("KeyNotFound", nil, err)
    t.eq(err.code, 10009)
    t.eq(err.message, "get: 'key not found'")
  end)
end)

t.describe("cloudflare error envelopes", function()
  t.it("success:false inside HTTP 200 is a failure, matched to the operation's error", function()
    local _, err = run(KV, "get_namespace", ns, {
      status = 200,
      body = error_envelope({ { code = 10013, message = "namespace not found" } }),
    })
    t.fails_with("NamespaceNotFound", nil, err)
    t.eq(err.code, 10013)
    t.eq(err.message, "namespace not found")
  end)

  t.it("the same typed error matches under a non-2xx status", function()
    local _, err = run(KV, "get_namespace", ns, {
      status = 404,
      body = error_envelope({ { code = 10013, message = "namespace not found" } }),
    })
    t.fails_with("NamespaceNotFound", nil, err)
  end)

  t.it("per-operation matchers win over the global code map", function()
    local _, typed = run(Zones, "get_zone", { zone_id = "z" }, {
      status = 400,
      body = error_envelope({ { code = 9109, message = "Invalid zone identifier" } }),
    })
    t.fails_with("InvalidZoneIdentifier", nil, typed)
    local _, global = run(Zones, "get_zone", { zone_id = "z" }, {
      status = 400,
      body = error_envelope({ { code = 9109, message = "Invalid access token" } }),
    })
    t.fails_with("Unauthorized", nil, global)
  end)

  t.it("an unknown code inside HTTP 200 falls back to UnknownCloudflareError", function()
    local _, err = run(
      KV,
      "get_namespace",
      ns,
      { body = error_envelope({ { code = 424242, message = "new" } }) }
    )
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(err.code, 424242)
    t.eq(err.message, "new")
    t.eq(err.status, 200)
  end)

  t.it("a missing error code is reported as code 0", function()
    local _, err =
      run(KV, "get_namespace", ns, { body = error_envelope({ { message = "webhook failed" } }) })
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(err.code, 0)
    t.eq(err.message, "webhook failed")
  end)

  t.it("an empty errors array reports the HTTP status as the message", function()
    local _, err = run(KV, "get_namespace", ns, { body = error_envelope({}) })
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(err.message, "HTTP 200")
    t.eq(err.code, nil)
  end)

  t.it("a top-level message is kept when errors carry none", function()
    local _, err = run(KV, "get_namespace", ns, {
      status = 400,
      body = json.encode({ success = false, message = "name is invalid", errors = json.array({}) }),
    })
    t.fails_with("BadRequest", nil, err)
    t.eq(err.message, "name is invalid")
  end)

  t.it("errors entries without a message are kept as JSON", function()
    local _, err = run(KV, "get_namespace", ns, {
      status = 400,
      body = json.encode({
        success = false,
        errors = json.array({ { code = 1001, path = json.array({ "name" }) } }),
      }),
    })
    t.fails_with("BadRequest", nil, err)
    t.eq(err.message, '[{"code":1001,"path":["name"]}]')
  end)

  t.it("a JSON body of an unfamiliar shape is kept, truncated to 1000 characters", function()
    local body = json.encode({ detail = string.rep("x", 2000) })
    local _, err = run(KV, "get_namespace", ns, { status = 400, body = body })
    t.fails_with("BadRequest", nil, err)
    t.eq(err.message, string.sub(body, 1, 1000))
  end)

  t.it("a top-level message lets an operation matcher on message match", function()
    local Workers = require("cloudflare.workers")
    local _, err = run(Workers, "create_observability_destination", {
      account_id = "acc",
      name = "a_b",
      enabled = true,
      configuration = {
        type = "logpush",
        logpush_dataset = "opentelemetry-logs",
        url = "https://example.com",
        headers = {},
      },
    }, { status = 400, body = json.encode({ success = false, message = "Bad Request" }) })
    t.fails_with("ObservabilityDestinationCreateFailed", nil, err)
  end)

  t.it("only the first envelope error is used", function()
    local _, err = run(KV, "get_namespace", ns, {
      body = error_envelope({
        { code = 424242, message = "first" },
        { code = 10013, message = "second" },
      }),
    })
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(err.code, 424242)
    t.eq(err.message, "first")
  end)
end)

t.describe("cloudflare global error codes", function()
  local function global_case(code, message, status, headers)
    local _, err = run(KV, "get_namespace", ns, {
      status = status or 400,
      headers = headers,
      body = error_envelope({ { code = code, message = message } }),
    })
    return err
  end

  t.it("971 inside HTTP 200 is TooManyRequests with the server's retry hint", function()
    local err = global_case(
      971,
      "Please wait and consider throttling your request speed",
      200,
      { ["retry-after"] = "7" }
    )
    t.fails_with("TooManyRequests", nil, err)
    t.eq(err.retry_after, 7)
  end)

  for _, code in ipairs({ 6003, 9103, 9106, 9109 }) do
    t.it(code .. " is Unauthorized", function()
      local err = global_case(code, "Invalid request headers")
      t.fails_with("Unauthorized", nil, err)
      t.eq(err.retryable, false)
    end)
  end

  t.it("10000 'Authentication error' is Unauthorized marked retryable; others are not", function()
    local blip = global_case(10000, "Authentication error", 403)
    t.fails_with("Unauthorized", nil, blip)
    t.eq(blip.retryable, true)
    local real = global_case(10000, "Invalid API Token", 403)
    t.fails_with("Unauthorized", nil, real)
    t.eq(real.retryable, false)
  end)

  t.it("10001 is Forbidden, retryable only for its transient messages", function()
    for _, message in ipairs({ "internal error", "Unable to authenticate request" }) do
      local err = global_case(10001, message, 403)
      t.fails_with("Forbidden", nil, err)
      t.eq(err.retryable, true)
    end
    local denied = global_case(10001, "Method not allowed for token", 403)
    t.fails_with("Forbidden", nil, denied)
    t.eq(denied.retryable, false)
  end)

  t.it("7003 is InvalidRoute on operations without their own class for it", function()
    local _, err = run(Zones, "get_zone", { zone_id = "z" }, {
      status = 400,
      body = error_envelope({ { code = 7003, message = "Could not route to /zones/z" } }),
    })
    t.fails_with("InvalidRoute", nil, err)
    t.eq(err.code, 7003)
    t.eq(err.message, "Could not route to /zones/z")
  end)

  t.it("1000 is split by message: timeout, internal error, otherwise unknown", function()
    t.fails_with("GatewayTimeout", nil, global_case(1000, "Request timeout"))
    t.fails_with("InternalServerError", nil, global_case(1000, "Internal server error"))
    t.fails_with("InternalServerError", nil, global_case(1000, "internal error"))
    -- \b: "timeouts" is not the word timeout
    t.fails_with("UnknownCloudflareError", nil, global_case(1000, "too many timeouts"))
    local other = global_case(1000, "Invalid user")
    t.fails_with("UnknownCloudflareError", nil, other)
    t.eq(other.code, 1000)
    t.eq(other.message, "Invalid user")
  end)

  t.it("transient auth messages mark per-operation typed errors retryable too", function()
    local err = global_case(10013, "Authentication error", 403)
    t.fails_with("NamespaceNotFound", nil, err)
    t.eq(err.retryable, true)
  end)

  t.it("a retryable blip is retried by the default policy", function()
    local host = testing.host({
      responses = {
        {
          status = 403,
          body = error_envelope({ { code = 10000, message = "Authentication error" } }),
        },
        { status = 200, body = envelope(namespace) },
      },
    })
    local client = KV.new({ host = host, api_token = "t" })
    local v, err = client:get_namespace(ns)
    t.eq(err, nil)
    t.same(v, namespace)
    t.eq(#host.requests, 2)
  end)
end)

t.describe("cloudflare status and throttling fallbacks", function()
  t.it("a rate-limit message with an unknown code is TooManyRequests under HTTP 200", function()
    local _, err = run(KV, "get_namespace", ns, {
      body = error_envelope({ { code = 424242, message = "You have been rate limited" } }),
    })
    t.fails_with("TooManyRequests", nil, err)
    local _, other = run(KV, "get_namespace", ns, {
      body = error_envelope({ { code = 424242, message = "We are throttling your request" } }),
    })
    t.fails_with("TooManyRequests", nil, other)
    local _, not_word = run(KV, "get_namespace", ns, {
      body = error_envelope({ { code = 424242, message = "ratelimits" } }),
    })
    t.fails_with("UnknownCloudflareError", nil, not_word)
  end)

  t.it("429 with a non-JSON body is TooManyRequests with the raw text as message", function()
    local _, err = run(
      KV,
      "get_namespace",
      ns,
      { status = 429, body = "slow down", headers = { ["retry-after"] = "3" } }
    )
    t.fails_with("TooManyRequests", nil, err)
    t.eq(err.message, "slow down")
    t.eq(err.retry_after, 3)
  end)

  t.it("a mapped 4xx with an unknown code uses the status class", function()
    local _, conflict = run(KV, "get_namespace", ns, {
      status = 409,
      body = error_envelope({ { code = 424242, message = "conflict" } }),
    })
    t.fails_with("Conflict", nil, conflict)
    t.eq(conflict.message, "conflict")
    local _, missing = run(KV, "get_namespace", ns, { status = 404, body = "" })
    t.fails_with("NotFound", nil, missing)
    t.eq(missing.message, "HTTP 404")
  end)

  t.it("an unmapped 4xx falls back to UnknownCloudflareError", function()
    local _, err = run(KV, "get_namespace", ns, {
      status = 418,
      body = error_envelope({ { code = 424242, message = "teapot" } }),
    })
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(err.code, 424242)
    t.eq(err.message, "teapot")
  end)

  t.it("an HTML 502 page is BadGateway carrying the body text", function()
    local _, err = run(KV, "get_namespace", ns, { status = 502, body = "<html>bad gateway</html>" })
    t.fails_with("BadGateway", nil, err)
    t.eq(err.message, "<html>bad gateway</html>")
  end)

  t.it("Cloudflare-specific 5xx statuses are InternalServerError", function()
    local _, err = run(KV, "get_namespace", ns, { status = 522, body = "Connection timed out" })
    t.fails_with("InternalServerError", nil, err)
    t.eq(err.message, "Connection timed out")
    t.eq(err.retryable, true)
  end)
end)

t.describe("cloudflare response validation", function()
  t.it("lenient mode returns a mismatched payload as read", function()
    local v = run(KV, "get_namespace", ns, { body = envelope({ id = 42, title = "kv" }) })
    t.same(v, { id = 42, title = "kv" })
  end)

  t.it("strict mode fails a mismatched payload with CloudflareParseError", function()
    local _, err = run(
      KV,
      "get_namespace",
      ns,
      { body = envelope({ id = 42, title = "kv" }) },
      { validation = "strict" }
    )
    t.fails_with("CloudflareParseError", nil, err)
  end)

  t.it("strict mode passes a matching payload, and Cloudflare's explicit nulls", function()
    local v, err = run(
      KV,
      "get_namespace",
      ns,
      { body = envelope(namespace) },
      { validation = "strict" }
    )
    t.eq(err, nil)
    t.same(v, namespace)
    local v2, err2 = run(KV, "get_namespace", ns, {
      body = envelope({ id = "ns", title = "kv", supports_url_encoding = json.null }),
    }, { validation = "strict" })
    t.eq(err2, nil)
    t.eq(v2.supports_url_encoding, json.null)
  end)

  t.it("a non-JSON 2xx body: lenient returns the text, strict fails", function()
    t.eq(run(KV, "get_namespace", ns, { body = "not json" }), "not json")
    t.eq(
      run(KV, "get_namespace_metadata", with(ns, { key_name = "k" }), { body = "plain" }),
      "plain"
    )
    local _, err = run(KV, "get_namespace", ns, { body = "not json" }, { validation = "strict" })
    t.fails_with("CloudflareParseError", nil, err)
  end)

  local unmodeled = envelope(with(namespace, { beta = true }))

  t.it("additional mode passes a payload key the schema does not model", function()
    local v, err = run(KV, "get_namespace", ns, { body = unmodeled }, { validation = "additional" })
    t.eq(err, nil)
    t.same(v, namespace)
  end)

  t.it("strict fails a payload key the schema does not model, at its key", function()
    local _, err = run(KV, "get_namespace", ns, { body = unmodeled }, { validation = "strict" })
    t.fails_with("CloudflareParseError", nil, err)
    t.same(err.cause.path, { "beta" })
  end)

  t.it("strict ignores the envelope's own keys", function()
    local v, err = run(KV, "get_namespace", ns, {
      body = envelope(namespace, { result_info = { page = 1 } }),
    }, { validation = "strict" })
    t.eq(err, nil)
    t.same(v, namespace)
  end)
end)

t.describe("cloudflare per-operation host (K2 data plane)", function()
  local stream = "0123456789abcdef0123456789abcdef"

  t.it("a host-marked operation goes to its own origin, filled from the label", function()
    local v, err, reqs = run(K2, "consume", {
      stream_id = stream,
      subscription_id = "sub",
      worker_id = "w1",
      max_records = 10,
    }, {
      body = envelope({
        batch_id = json.null,
        leased_until_ms = json.null,
        records = json.array({}),
      }),
    })
    t.eq(err, nil)
    t.same(v, { batch_id = json.null, leased_until_ms = json.null, records = {} })
    t.eq(reqs[1].url, "https://" .. stream .. ".k2.cloudflarestorage.com/subscriptions/sub/consume")
    -- the host label is consumed: the body carries only the body members
    t.same(json.decode(reqs[1].body), { worker_id = "w1", max_records = 10 })
    t.eq(reqs[1].headers.authorization, "Bearer cf-token")
  end)

  t.it("a custom base_url does not move a host-marked operation", function()
    local _, _, reqs = run(
      K2,
      "produce",
      { stream_id = stream, records = json.array({ { content = "aGk=" } }) },
      { body = json.encode({ success = true }) },
      { base_url = "https://cf.test/v4" }
    )
    t.eq(reqs[1].url, "https://" .. stream .. ".k2.cloudflarestorage.com/produce")
  end)

  t.it("a host label left unset is InvalidInput, before any request", function()
    local _, err, reqs = run(K2, "produce", { records = json.array({}) }, { body = "" })
    t.fails_with("InvalidInput", nil, err)
    t.match(err.message, "the host label stream_id is required", true)
    t.eq(err.member, "stream_id")
    t.eq(#reqs, 0)
  end)

  t.it("operations without a host keep the API base URL", function()
    local _, _, reqs = run(
      K2,
      "get_stream",
      { account_id = "acc", stream_id = stream },
      { body = envelope({ id = stream }) }
    )
    t.eq(reqs[1].url, BASE .. "/accounts/acc/k2/streams/" .. stream)
  end)
end)

t.describe("cloudflare single `error` envelopes (K2 produce)", function()
  local stream = "0123456789abcdef0123456789abcdef"
  local function produce_error(status, code, retryable)
    return {
      status = status,
      body = json.encode({
        success = false,
        error = { code = code, message = "code " .. code, retryable = retryable },
      }),
    }
  end
  local input = { stream_id = stream, records = json.array({ { content = "aGk=" } }) }

  t.it("the code inside `error` selects the typed class", function()
    local _, err = run(K2, "produce", input, produce_error(404, 10200, false))
    t.fails_with("K2StreamNotFound", nil, err)
    t.eq(err.message, "code 10200")
  end)

  t.it("an append with an unknown outcome (503 / 10212) is never retried", function()
    local host = testing.host({
      responses = { produce_error(503, 10212, false), produce_error(503, 10212, false) },
    })
    local client = K2.new({ host = host, api_token = "t" })
    local _, err = client:produce(input)
    t.fails_with("K2AppendOutcomeUnknown", nil, err)
    t.eq(#host.requests, 1)
  end)

  t.it("a batch K2 did not store (503 / 10211) is retryable", function()
    local _, err = run(K2, "produce", input, produce_error(503, 10211, true))
    t.fails_with("K2Unavailable", nil, err)
    t.truthy(require("distilled.errors").is_transient(err))
  end)
end)

t.describe("cloudflare verbatim payloads (Pipelines ingest)", function()
  t.it("event keys are sent exactly as given", function()
    local records = json.array({
      { createdAt = 1, accountId = "a", nested = { tableName = "t" } },
    })
    local v, err, reqs = run(
      Pipelines,
      "send_stream_records",
      { stream_id = "0123456789abcdef0123456789abcdef", records = records },
      { body = json.encode({ success = true, result = { committed = 1 } }) }
    )
    t.eq(err, nil)
    t.same(v, { committed = 1 })
    t.eq(reqs[1].url, "https://0123456789abcdef0123456789abcdef.ingest.cloudflare.com/")
    t.same(json.decode(reqs[1].body), records)
  end)
end)

t.describe("cloudflare protocol helpers", function()
  t.it("camel_to_snake is protocol.ts camelToSnake", function()
    t.eq(cloudflare.camel_to_snake("someNewField"), "some_new_field")
    t.eq(cloudflare.camel_to_snake("already_snake"), "already_snake")
    t.eq(cloudflare.camel_to_snake("a1B"), "a1_b")
  end)

  t.it("the protocol module is callable as a provider-spec protocol module", function()
    local p = cloudflare({}, { unknown_tag = "U", parse_tag = "P" })
    t.eq(type(p.call), "function")
    t.eq(p.unknown_class.tag, "U")
  end)

  t.it("a raw (non-table) error message never breaks message tests", function()
    t.eq(cloudflare._test_pattern("rate_limit", "RATE LIMITED"), true)
    t.eq(cloudflare._test_pattern("timeout", "timeout"), true)
    t.eq(cloudflare._test_pattern("timeout", "timeouts"), false)
  end)
end)

t.describe("cloudflare opAliases (generator.ts alias re-exports)", function()
  t.it("an alias is a second method on the same route", function()
    local reply = { body = envelope({ successful_key_count = 1 }) }
    local input = { account_id = "a", namespace_id = "n", body = json.array({ "k" }) }
    local v1, e1, r1 = run(KV, "bulk_delete_namespaces", input, reply)
    local v2, e2, r2 = run(KV, "bulk_delete_namespace_keys", input, reply)
    t.eq(e1, nil)
    t.eq(e2, nil)
    t.same(v2, v1)
    t.eq(r2[1].method, r1[1].method)
    t.eq(r2[1].url, BASE .. "/accounts/a/storage/kv/namespaces/n/bulk/delete")
    t.eq(r2[1].url, r1[1].url)
    t.eq(r2[1].body, r1[1].body)
  end)

  t.it("the alias keeps the target's errors", function()
    local input = { account_id = "a", namespace_id = "n", body = json.array({ "k" }) }
    local reply = { status = 404, body = error_envelope({ { code = 10013, message = "x" } }) }
    local _, e1 = run(KV, "bulk_delete_namespaces", input, reply)
    local _, e2 = run(KV, "bulk_delete_namespace_keys", input, reply)
    t.eq(e2.tag, e1.tag)
  end)
end)
