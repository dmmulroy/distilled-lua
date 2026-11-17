-- The Tencent Cloud protocol (distilled.protocol.tencentcloud) through the generated
-- clients: credentials and region resolution, endpoints, the error envelope with the
-- retry loop, secrets kept out of everything visible, spans. Cases ported from
-- Distilled's packages/tencentcloud/test/protocol.test.ts where they exist; the
-- byte-level comparison with Distilled is spec/tencentcloud_conform_spec.lua.
local t = require("spec.harness")
local errors = require("distilled.errors")
local json = require("distilled.json")
local secret = require("distilled.secret")
local signer = require("distilled.tencentcloud.signer")
local tc = require("distilled.protocol.tencentcloud")
local tc_errors = require("distilled.tencentcloud.errors")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local SECRET_KEY = "sentinel-secret-key-7f3a"
local TOKEN = "sts-token-sentinel-91"

local function ok_body(payload)
  payload = payload or {}
  payload.RequestId = "req-1"
  return { Response = payload }
end

local function failure(code, message)
  return { Response = { Error = { Code = code, Message = message or "boom" }, RequestId = "req-2" } }
end

-- a cvm client over scripted responses; opts are merged over the defaults
local function cvm(responses, opts, env)
  local host = testing.host({ responses = responses, env = env or {} })
  local o = { host = host, secret_id = "AKIDtest", secret_key = SECRET_KEY, retry = "none" }
  for k, v in pairs(opts or {}) do
    o[k] = v
  end
  for k, v in pairs(o) do
    if v == false then
      o[k] = nil
    end
  end
  return require("tencentcloud.cvm").new(o), host
end

t.describe("tencentcloud request", function()
  t.it("POSTs the input as JSON to the product host, signed (protocol.test.ts)", function()
    local c, host = cvm({ { status = 200, body = ok_body({ TotalCount = 0, InstanceSet = {} }) } })
    local v, err =
      c:describe_instances({ region = "ap-guangzhou", Limit = 1, InstanceIds = { "ins-1" } })
    t.eq(err, nil)
    t.eq(v.RequestId, "req-1")
    t.eq(v.TotalCount, 0)
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://cvm.tencentcloudapi.com/")
    t.eq(req.body, '{"InstanceIds":["ins-1"],"Limit":1}')
    local h = req.headers
    t.eq(h["content-type"], tc.CONTENT_TYPE)
    t.eq(h["x-tc-action"], "DescribeInstances")
    t.eq(h["x-tc-version"], "2017-03-12")
    t.eq(h["x-tc-region"], "ap-guangzhou")
    t.eq(h["x-tc-token"], nil)
    t.eq(h["x-tc-timestamp"], "1700000000")
    local expected = signer.sign({
      secret_id = "AKIDtest",
      secret_key = SECRET_KEY,
      service = "cvm",
      host = "cvm.tencentcloudapi.com",
      action = "DescribeInstances",
      timestamp = 1700000000,
      content_type = tc.CONTENT_TYPE,
      payload = req.body,
    })
    t.eq(h.authorization, expected.authorization)
    t.no_match(h.authorization, SECRET_KEY, true)
  end)

  t.it("sends the session token of temporary credentials; dnspod has its own host", function()
    local host = testing.host({ responses = { { status = 200, body = ok_body() } } })
    local c = require("tencentcloud.dnspod").new({
      host = host,
      secret_id = "AKIDtest",
      secret_key = SECRET_KEY,
      session_token = secret.wrap(TOKEN),
    })
    local _, err = c:describe_domain_list({})
    t.eq(err, nil)
    t.eq(host.requests[1].headers["x-tc-token"], TOKEN)
    t.eq(host.requests[1].url, "https://dnspod.tencentcloudapi.com/")
    t.eq(host.requests[1].body, "{}")
    t.eq(host.requests[1].headers["x-tc-region"], nil)
  end)

  t.it("reads TENCENTCLOUD_SECRET_ID / _SECRET_KEY / _SESSION_TOKEN / _REGION", function()
    local c, host = cvm(
      { { status = 200, body = ok_body() } },
      { secret_id = false, secret_key = false },
      {
        TENCENTCLOUD_SECRET_ID = "AKIDenv",
        TENCENTCLOUD_SECRET_KEY = SECRET_KEY,
        TENCENTCLOUD_SESSION_TOKEN = TOKEN,
        TENCENTCLOUD_REGION = "ap-chengdu",
      }
    )
    local _, err = c:describe_instances({})
    t.eq(err, nil)
    local h = host.requests[1].headers
    t.match(h.authorization, "Credential=AKIDenv/2023-11-14/cvm/tc3_request", true)
    t.eq(h["x-tc-token"], TOKEN)
    t.eq(h["x-tc-region"], "ap-chengdu")
  end)

  t.it("fails with ConfigError naming the variable when no key is set, sending nothing", function()
    local c, host = cvm({}, { secret_key = false })
    local _, err = c:describe_instances({})
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "secret_key")
    t.match(err.message, "TENCENTCLOUD_SECRET_KEY", true)
    t.eq(#host.requests, 0)
    local c2 = cvm({}, { secret_id = false })
    local _, err2 = c2:describe_instances({})
    t.eq(err2.key, "secret_id")
  end)

  t.it("region: the input wins over the client option, which wins over the environment", function()
    local function region_of(input, opts, env)
      local c, host = cvm({ { status = 200, body = ok_body() } }, opts, env)
      local _, err = c:describe_instances(input)
      t.eq(err, nil)
      return host.requests[1].headers["x-tc-region"]
    end
    local env = { TENCENTCLOUD_REGION = "ap-guangzhou" }
    t.eq(region_of({ region = "ap-beijing" }, { region = "ap-shanghai" }, env), "ap-beijing")
    t.eq(region_of({}, { region = "ap-shanghai" }, env), "ap-shanghai")
    t.eq(region_of({}, nil, env), "ap-guangzhou")
    t.eq(region_of({}, nil, nil), nil)
    t.eq(region_of({}, { region = "" }, nil), nil)
    -- client:with scopes a region, as Distilled's Region layer does
    local c, host = cvm({ { status = 200, body = ok_body() } }, { region = "ap-guangzhou" })
    local _, err = c:with({ region = "eu-frankfurt" }):describe_instances({})
    t.eq(err, nil)
    t.eq(host.requests[1].headers["x-tc-region"], "eu-frankfurt")
  end)

  t.it("root_domain and endpoint move the host; the signed host follows", function()
    local c, host = cvm(
      { { status = 200, body = ok_body() } },
      { root_domain = "internal.tencentcloudapi.com" }
    )
    t.eq(select(2, c:describe_instances({})), nil)
    t.eq(host.requests[1].url, "https://cvm.internal.tencentcloudapi.com/")
    local c2, host2 = cvm(
      { { status = 200, body = ok_body() } },
      { endpoint = "http://127.0.0.1:8080/{service}/" }
    )
    t.eq(select(2, c2:describe_instances({ Limit = 2 })), nil)
    local req = host2.requests[1]
    t.eq(req.url, "http://127.0.0.1:8080/cvm/")
    local expected = signer.sign({
      secret_id = "AKIDtest",
      secret_key = SECRET_KEY,
      service = "cvm",
      host = "127.0.0.1:8080",
      action = "DescribeInstances",
      timestamp = 1700000000,
      content_type = tc.CONTENT_TYPE,
      payload = req.body,
    })
    t.eq(req.headers.authorization, expected.authorization)
    local c3 = cvm({}, { root_domain = "bad domain/x" })
    t.eq(select(2, c3:describe_instances({})).tag, "ConfigError")
    local c4 = cvm({}, { endpoint = "ftp://x" })
    t.eq(select(2, c4:describe_instances({})).key, "endpoint")
  end)

  t.it("secrets in the input are unwrapped into the body only; the key never leaves", function()
    local c, host = cvm({ { status = 200, body = ok_body() } })
    local _, err = c:run_instances({ LoginSettings = { Password = secret.wrap("pw-sentinel") } })
    t.eq(err, nil)
    local req = host.requests[1]
    t.match(req.body, '"Password":"pw-sentinel"', true)
    for name, value in pairs(req.headers) do
      t.no_match(value, SECRET_KEY, true, name)
    end
    t.no_match(req.body, SECRET_KEY, true)
  end)

  t.it("an operation without its action fails with SdkError before sending", function()
    local p = tc.new({ shapes = {}, ops = {} }, {})
    local _, err = p.encode(
      {},
      { name = "X", method = "POST", uri = "/" },
      {},
      { secret_id = "a", secret_key = "b" }
    )
    t.eq(err.tag, "SdkError")
    t.match(err.message, "has no Tencent Cloud action", true)
  end)
end)

t.describe("tencentcloud response", function()
  local function error_of(status, body, opts)
    local c = cvm({ { status = status, body = body } }, opts)
    local v, err = c:describe_instances({})
    t.eq(v, nil)
    return err
  end

  t.it("maps a common code by its first segment, keeping the full code", function()
    local err = error_of(200, failure("ResourceNotFound.InstanceNotExist", "gone"))
    t.eq(err.tag, "ResourceNotFound")
    t.eq(err.code, "ResourceNotFound.InstanceNotExist")
    t.eq(err.message, "gone")
    t.eq(err.request_id, "req-2")
    t.truthy(errors.has_category(err, "NotFoundError"))
  end)

  t.it("every common code has its class and categories", function()
    t.eq(#tc_errors.TAGS, 27)
    for _, tag in ipairs(tc_errors.TAGS) do
      local err = error_of(200, failure(tag .. ".X"))
      t.eq(err.tag, tag)
    end
    t.truthy(
      errors.has_category(error_of(200, failure("AuthFailure.SignatureFailure")), "AuthError")
    )
    t.truthy(errors.has_category(error_of(200, failure("LimitExceeded")), "QuotaError"))
  end)

  t.it("throttling and internal errors are retryable, client errors are not", function()
    local throttled = error_of(200, failure("RequestLimitExceeded"))
    t.eq(throttled.tag, "RequestLimitExceeded")
    t.truthy(errors.is_throttling(throttled))
    t.truthy(errors.is_transient(throttled))
    t.truthy(errors.is_transient(error_of(200, failure("InternalError.DbError"))))
    t.falsy(errors.is_transient(error_of(200, failure("InvalidParameterValue.Range"))))
  end)

  t.it(
    "ServiceUnavailable is the core class; a product code is UnknownTencentCloudError",
    function()
      local err = error_of(200, failure("ServiceUnavailable"))
      t.eq(err.tag, "ServiceUnavailable")
      t.truthy(errors.is_transient(err))
      local unknown = error_of(200, failure("InvalidInstanceId.NotFound"))
      t.eq(unknown.tag, "UnknownTencentCloudError")
      t.eq(unknown.code, "InvalidInstanceId.NotFound")
      t.eq(unknown.request_id, "req-2")
      t.eq(unknown.status, 200)
      t.falsy(errors.is_transient(unknown))
    end
  )

  t.it(
    "a failure without the envelope maps by HTTP status; a 2xx without it is a parse error",
    function()
      t.eq(error_of(502, "<html>bad gateway</html>").tag, "BadGateway")
      t.eq(error_of(502, "<html>bad gateway</html>").message, "<html>bad gateway</html>")
      t.eq(error_of(599, "").tag, "InternalServerError")
      local teapot = error_of(418, '{"tea":true}')
      t.eq(teapot.tag, "UnknownTencentCloudError")
      t.eq(teapot.status, 418)
      local parse = error_of(200, { TotalCount = 1 })
      t.eq(parse.tag, "TencentCloudParseError")
      t.truthy(errors.has_category(parse, "ParseError"))
      t.match(parse.message, "no `Response` envelope", true)
      t.eq(error_of(200, "").tag, "TencentCloudParseError")
      t.eq(error_of(200, "not json").tag, "TencentCloudParseError")
    end
  )

  t.it("strict validation rejects a mistyped output member; lenient keeps it", function()
    local body = ok_body({ TotalCount = "many" })
    t.eq(error_of(200, body, { validation = "strict" }).tag, "TencentCloudParseError")
    local c = cvm({ { status = 200, body = body } })
    local v = c:describe_instances({})
    t.eq(v.TotalCount, "many")
  end)

  t.it("a transport failure is TransportError", function()
    local c = cvm({
      function()
        return nil, errors.new("TransportError", { message = "reset" })
      end,
    })
    local _, err = c:describe_instances({})
    t.eq(err.tag, "TransportError")
  end)
end)

t.describe("tencentcloud retries", function()
  t.it("RequestLimitExceeded at HTTP 200 is retried, then the call succeeds", function()
    local c, host = cvm({
      { status = 200, body = failure("RequestLimitExceeded", "slow down") },
      { status = 200, body = failure("InternalError", "oops") },
      { status = 200, body = ok_body({ TotalCount = 3 }) },
    }, { retry = false })
    local v, err = c:describe_instances({})
    t.eq(err, nil)
    t.eq(v.TotalCount, 3)
    t.eq(#host.requests, 3)
    t.eq(#host.sleeps, 2)
    -- each try is signed again with its own timestamp
    t.ne(host.requests[1].headers["x-tc-timestamp"], nil)
  end)

  t.it("a client error is not retried", function()
    local c, host = cvm(
      { { status = 200, body = failure("AuthFailure.SignatureFailure") } },
      { retry = false }
    )
    local _, err = c:describe_instances({})
    t.eq(err.tag, "AuthFailure")
    t.eq(#host.requests, 1)
  end)

  t.it("a 503 without the envelope is retried with its Retry-After hint", function()
    local c, host = cvm({
      { status = 503, headers = { ["retry-after"] = "2" }, body = "" },
      { status = 200, body = ok_body() },
    }, { retry = false })
    local _, err = c:describe_instances({})
    t.eq(err, nil)
    t.eq(#host.requests, 2)
    t.eq(host.sleeps[1], 2)
  end)
end)

t.describe("tencentcloud spans", function()
  t.it("the operation span has Distilled's names", function()
    local trace = require("distilled.trace")
    local memory = trace.exporters.memory()
    local c = cvm({ { status = 200, headers = { ["x-request-id"] = "r1" }, body = ok_body() } }, {
      tracing = { level = "operation", exporter = memory },
    })
    t.eq(select(2, c:describe_instances({})), nil)
    t.eq(#memory.spans, 1)
    local span = memory.spans[1]
    t.eq(span.name, "TencentCloud.DescribeInstances")
    t.eq(span.attributes["rpc.method"], "cvm/DescribeInstances")
    t.eq(span.attributes["rpc.system.name"], "tencentcloud-api")
    t.eq(span.attributes["http.request.method"], "POST")
    t.eq(span.attributes["server.address"], "cvm.tencentcloudapi.com")
    t.eq(span.attributes["http.response.status_code"], 200)
    local text = json.encode(memory.spans)
    t.no_match(text, SECRET_KEY, true)
  end)
end)

t.describe("tencentcloud over HTTP (dl serve)", function()
  t.it("a signed call through the real transport, retried on RequestLimitExceeded", function()
    local serve = require("verify.lib.serve")
    if not serve.url() then
      t.pending("DL_SERVE_URL is not set (run verify/dl test --http)")
      return
    end
    local h = require("verify.lib.canary").host()
    local s = serve.client(h.transport)
    s.reset()
    s.script("/tc/cvm/", {
      { status = 200, json = failure("RequestLimitExceeded", "slow down") },
      { status = 200, json = ok_body({ TotalCount = 7 }) },
    })
    local c = require("tencentcloud.cvm").new({
      host = h,
      secret_id = "AKIDhttp",
      secret_key = SECRET_KEY,
      endpoint = serve.url() .. "/tc/{service}",
      retry = { base_ms = 10, max_retries = 2 },
    })
    local v, err = c:describe_instances({ region = "ap-guangzhou", Limit = 7 })
    t.eq(err, nil)
    t.eq(v.TotalCount, 7)
    local seen = s.requests()
    t.eq(#seen, 2)
    local r = seen[2]
    t.eq(r.method, "POST")
    t.eq(r.body, '{"Limit":7}')
    local hd = {}
    for k, x in pairs(r.headers) do
      hd[string.lower(k)] = x
    end
    t.eq(hd["x-tc-action"], "DescribeInstances")
    t.eq(hd["x-tc-region"], "ap-guangzhou")
    local expected = signer.sign({
      secret_id = "AKIDhttp",
      secret_key = SECRET_KEY,
      service = "cvm",
      host = hd.host,
      action = "DescribeInstances",
      timestamp = tonumber(hd["x-tc-timestamp"]),
      content_type = hd["content-type"],
      payload = r.body,
    })
    t.eq(hd.authorization, expected.authorization)
  end)
end)
