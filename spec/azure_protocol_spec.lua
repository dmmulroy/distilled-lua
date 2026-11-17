-- The Azure protocol (lua/distilled/protocol/azure.lua) through the generated clients
-- (clients/azure) over the scripted transport. Ports Distilled's
-- packages/azure/test/protocol.test.ts (request encoding, the ARM error envelope,
-- success decoding) and adds what the Lua runtime does around it: options from the
-- environment on every request, the subscription id rule, retries, the refresh of a
-- function token after a 401, the Entra ID client-credentials exchange, and secrets kept
-- out of errors. Cases named "(protocol.test.ts)" follow the TS test of that name.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local S = require("distilled.schema")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Resources = require("azure.resources")
local Authorization = require("azure.authorization")
local Communication = require("azure.communication")
local AppConfiguration = require("azure.appconfiguration")
local azure = require("distilled.protocol.azure")

local SUB = "00000000-0000-0000-0000-000000000001"
local TOKEN = "arm-token-SPEC-7f3a"
local SECRET = "sentinel-secret-7f3a"
local BASE = "https://management.azure.com"

local function host_with(responses, env, exec)
  return testing.host({ responses = responses, env = env or {}, exec = exec })
end

local function new(Class, responses, opts)
  opts = opts or {}
  local host = host_with(responses, opts.env, opts.exec)
  local o = { host = host, retry = opts.retry or "none" }
  if opts.bearer_token ~= false then
    o.bearer_token = opts.bearer_token or TOKEN
  end
  if opts.subscription_id ~= false then
    o.subscription_id = opts.subscription_id or SUB
  end
  for k, v in pairs(opts.extra or {}) do
    o[k] = v
  end
  return Class.new(o), host
end

local function ok(body, headers)
  return { status = 200, body = body and json.encode(body) or "{}", headers = headers or {} }
end

local rg = { subscriptionId = SUB, resourceGroupName = "my-rg" }

local function arm_error(code, message, extra)
  local e = { code = code, message = message }
  for k, v in pairs(extra or {}) do
    e[k] = v
  end
  return json.encode({ error = e })
end

t.describe("azure protocol: request encoding", function()
  t.it("sends Bearer auth and Accept: application/json (protocol.test.ts)", function()
    local c, host = new(Resources, { ok({ location = "westus" }) })
    local v, err = c:get_resource_group(rg)
    t.eq(err, nil)
    t.eq(v.location, "westus")
    t.eq(host.requests[1].headers.authorization, "Bearer " .. TOKEN)
    t.eq(host.requests[1].headers.accept, "application/json")
  end)

  t.it("reads AZURE_BEARER_TOKEN on every request (resolves credentials per request)", function()
    local env = { AZURE_BEARER_TOKEN = "t1", AZURE_SUBSCRIPTION_ID = SUB }
    local c, host = new(
      Resources,
      { ok({}), ok({}) },
      { env = env, bearer_token = false, subscription_id = false }
    )
    t.eq(select(2, c:get_resource_group(rg)), nil)
    env.AZURE_BEARER_TOKEN = "t2"
    t.eq(select(2, c:get_resource_group(rg)), nil)
    t.eq(host.requests[1].headers.authorization, "Bearer t1")
    t.eq(host.requests[2].headers.authorization, "Bearer t2")
  end)

  t.it("appends the operation's api-version to every request (protocol.test.ts)", function()
    local c, host = new(Resources, { ok({}) })
    c:get_resource_group(rg)
    t.eq(
      host.requests[1].url,
      BASE .. "/subscriptions/" .. SUB .. "/resourcegroups/my-rg?api-version=2025-04-01"
    )
  end)

  t.it("api-version follows existing query parameters, with $-prefixed wire names", function()
    local c, host = new(Resources, { ok({ value = json.array({}) }) })
    c:list_resource_groups({ subscriptionId = SUB, _filter = "tagName eq 'env'", _top = 5 })
    t.eq(
      host.requests[1].url,
      BASE
        .. "/subscriptions/"
        .. SUB
        .. "/resourcegroups?%24filter=tagName+eq+%27env%27&%24top=5&api-version=2025-04-01"
    )
  end)

  t.it("an api-version already in the URL wins", function()
    local service = {
      shapes = {
        In = S.struct({
          name = "In",
          members = {
            S.member({ name = "v", bind = "query", wire = "api-version", schema = S.string }),
          },
        }),
      },
      ops = {
        get_thing = {
          name = "GetThing",
          method = "GET",
          uri = "/things",
          input = S.ref("In"),
          api_version = "2025-01-01",
        },
      },
    }
    local p = azure.new(service)
    local req, err = p.encode({ service = service }, service.ops.get_thing, { v = "2019-01-01" }, {
      bearer_token = "x",
    })
    t.eq(err, nil)
    t.eq(req.url, BASE .. "/things?api-version=2019-01-01")
    req = p.encode({ service = service }, service.ops.get_thing, {}, { bearer_token = "x" })
    t.eq(req.url, BASE .. "/things?api-version=2025-01-01")
  end)

  t.it("uses the api_base_url option, or AZURE_API_BASE_URL (protocol.test.ts)", function()
    local c, host = new(
      Resources,
      { ok({}) },
      { extra = { api_base_url = "https://management.usgovcloudapi.net" } }
    )
    c:get_resource_group(rg)
    t.match(host.requests[1].url, "^https://management%.usgovcloudapi%.net/subscriptions/")
    local c2, host2 = new(
      Resources,
      { ok({}) },
      { env = { AZURE_API_BASE_URL = "https://management.chinacloudapi.cn" } }
    )
    c2:get_resource_group(rg)
    t.match(host2.requests[1].url, "^https://management%.chinacloudapi%.cn/subscriptions/")
  end)

  t.it(
    "injects subscriptionId from the options when the caller omits it (protocol.test.ts)",
    function()
      local c, host = new(Resources, { ok({}) })
      local input = { resourceGroupName = "my-rg" }
      t.eq(select(2, c:get_resource_group(input)), nil)
      t.match(host.requests[1].url, "/subscriptions/" .. SUB .. "/resourcegroups/my-rg?", true)
      t.eq(input.subscriptionId, nil, "the caller's table is not changed")
    end
  )

  t.it("takes the subscription id from AZURE_SUBSCRIPTION_ID", function()
    local c, host = new(
      Resources,
      { ok({}) },
      { subscription_id = false, env = { AZURE_SUBSCRIPTION_ID = "env-sub" } }
    )
    c:get_resource_group({ resourceGroupName = "rg" })
    t.match(host.requests[1].url, "/subscriptions/env-sub/resourcegroups/rg?", true)
  end)

  t.it("an explicit subscriptionId wins over the options' one (protocol.test.ts)", function()
    local c, host = new(Resources, { ok({}) })
    c:get_resource_group({ subscriptionId = "other-sub", resourceGroupName = "rg" })
    t.match(host.requests[1].url, "/subscriptions/other-sub/resourcegroups/rg?", true)
  end)

  t.it("no subscription id anywhere is a ConfigError naming the option; nothing is sent", function()
    local c, host = new(Resources, {}, { subscription_id = false })
    local v, err = c:get_resource_group({ resourceGroupName = "rg" })
    t.eq(v, nil)
    t.fails_with("ConfigError", v, err)
    t.eq(err.key, "subscription_id")
    t.match(err.message, "AZURE_SUBSCRIPTION_ID", true)
    t.eq(#host.requests, 0)
  end)

  t.it("an operation without {subscriptionId} needs no subscription id", function()
    local c, host = new(Resources, { ok({ value = json.array({}) }) }, { subscription_id = false })
    local _, err = c:list_tenants({})
    t.eq(err, nil)
    t.eq(host.requests[1].url, BASE .. "/tenants?api-version=2022-12-01")
  end)

  t.it("plain labels are percent-encoded (protocol.test.ts)", function()
    local c, host = new(Resources, { ok({}) })
    c:get_resource_group({ subscriptionId = SUB, resourceGroupName = "a b/c" })
    t.match(host.requests[1].url, "/resourcegroups/a%20b%2Fc?", true)
  end)

  t.it("greedy {scope+} labels keep '/' and drop a leading slash (protocol.test.ts)", function()
    local c, host = new(Authorization, { ok({}) })
    local _, err = c:get_role_assignment({
      scope = "/subscriptions/" .. SUB .. "/resourceGroups/my rg",
      roleAssignmentName = "ra-1",
    })
    t.eq(err, nil)
    t.eq(
      host.requests[1].url,
      BASE
        .. "/subscriptions/"
        .. SUB
        .. "/resourceGroups/my%20rg/providers/Microsoft.Authorization/roleAssignments/ra-1"
        .. "?api-version=2022-04-01"
    )
  end)

  t.it("body members are sent as the JSON body (protocol.test.ts)", function()
    local c, host = new(Authorization, { ok({}) })
    local properties = {
      roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/r",
      principalId = "p",
      principalType = "ServicePrincipal",
    }
    c:create_role_assignment({
      scope = "subscriptions/" .. SUB,
      roleAssignmentName = "ra-1",
      properties = properties,
    })
    t.eq(host.requests[1].method, "PUT")
    t.eq(json.encode(json.decode(host.requests[1].body)), json.encode({ properties = properties }))
  end)

  t.it("secret inputs are unwrapped on the wire (protocol.test.ts)", function()
    local c, host = new(Communication, { ok({ resourceId = "hub" }) })
    local _, err = c:communication_services_link_notification_hub({
      subscriptionId = SUB,
      resourceGroupName = "rg",
      communicationServiceName = "comm",
      resourceId = "hub",
      connectionString = secret.wrap("Endpoint=sb://secret"),
    })
    t.eq(err, nil)
    t.eq(
      json.encode(json.decode(host.requests[1].body)),
      json.encode({ connectionString = "Endpoint=sb://secret", resourceId = "hub" })
    )
  end)

  t.it("no token and no client credentials is a ConfigError; nothing is sent", function()
    local c, host = new(Resources, {}, { bearer_token = false })
    local v, err = c:get_resource_group(rg)
    t.fails_with("ConfigError", v, err)
    t.match(err.message, "bearer_token", true)
    t.eq(#host.requests, 0)
  end)
end)

t.describe("azure protocol: ARM error envelope decoding", function()
  local function fail_with(status, body, headers)
    local c = new(Resources, { { status = status, body = body, headers = headers or {} } })
    local v, err = c:get_resource_group(rg)
    t.eq(v, nil)
    t.truthy(err, "an error")
    return err
  end

  t.it(
    "error.code dispatches to the mapped class with code, message and target (protocol.test.ts)",
    function()
      local err = fail_with(
        404,
        arm_error(
          "ResourceGroupNotFound",
          "Resource group 'my-rg' could not be found.",
          { target = "my-rg" }
        )
      )
      t.eq(err.tag, "ResourceGroupNotFound")
      t.eq(err.categories.NotFoundError, true)
      t.eq(err.code, "ResourceGroupNotFound")
      t.eq(err.message, "Resource group 'my-rg' could not be found.")
      t.eq(err.target, "my-rg")
      t.eq(err.status, 404)
    end
  )

  t.it("the flat { code, message } shape is accepted (protocol.test.ts)", function()
    local err =
      fail_with(401, json.encode({ code = "InvalidAuthenticationToken", message = "expired" }))
    t.eq(err.tag, "InvalidAuthenticationToken")
    t.eq(err.message, "expired")
  end)

  t.it("PascalCase Code/Message (legacy RPs) are accepted (protocol.test.ts)", function()
    local err = fail_with(
      404,
      json.encode({ Code = "ResourceNotFound", Message = "The resource was not found." })
    )
    t.eq(err.tag, "ResourceNotFound")
    t.eq(err.code, "ResourceNotFound")
    t.eq(err.message, "The resource was not found.")
  end)

  t.it("message matchers win over the code map (protocol.test.ts)", function()
    local err = fail_with(
      409,
      arm_error("409", "The managed HSM pool is still updating its spec. Retry later.")
    )
    t.eq(err.tag, "ManagedHsmPoolUpdating")
  end)

  t.it(
    "a mapped nested details[].code is used when the top-level code is generic (protocol.test.ts)",
    function()
      local err = fail_with(
        400,
        arm_error("ValidationError", "Validation failed", {
          target = "t",
          details = json.array({
            { code = "SomethingUnmapped", message = "ignored" },
            { code = "ResourceNotFound", message = "The parent was not found." },
          }),
        })
      )
      t.eq(err.tag, "ResourceNotFound")
      t.eq(err.code, "ResourceNotFound")
      t.eq(err.message, "The parent was not found.")
      t.eq(err.target, "t")
    end
  )

  t.it("unmapped codes fall back to the HTTP status class (protocol.test.ts)", function()
    local err = fail_with(404, arm_error("SomeNewCode", "Gone fishing"))
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "Gone fishing")
  end)

  t.it("retryable statuses honor Retry-After (protocol.test.ts)", function()
    local err = fail_with(429, arm_error("SomeThrottle", "slow down"), { ["retry-after"] = "12" })
    t.eq(err.tag, "TooManyRequests")
    t.eq(err.retry_after, 12)
  end)

  t.it("a non-JSON error body becomes the trimmed message (protocol.test.ts)", function()
    local err = fail_with(404, "  <html>not here</html>\n")
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "<html>not here</html>")
  end)

  t.it("a bare JSON string body becomes the message (protocol.test.ts)", function()
    local err = fail_with(418, json.encode("Guest configuration says no"))
    t.eq(err.tag, "UnknownAzureError")
    t.eq(err.message, "Guest configuration says no")
    t.eq(err.body, "Guest configuration says no")
  end)

  t.it("unmapped 5xx becomes a retryable InternalServerError (protocol.test.ts)", function()
    local err = fail_with(507, "")
    t.eq(err.tag, "InternalServerError")
    t.eq(err.message, "HTTP 507")
    t.eq(err.retryable, true)
  end)

  t.it(
    "unmapped 4xx becomes UnknownAzureError with the ARM fields and body (protocol.test.ts)",
    function()
      local err = fail_with(
        418,
        json.encode({ error = { code = "Teapot", message = "short and stout", target = "pot" } })
      )
      t.eq(err.tag, "UnknownAzureError")
      t.eq(err.code, "Teapot")
      t.eq(err.message, "short and stout")
      t.eq(err.target, "pot")
      t.eq(err.body.error.code, "Teapot")
      t.eq(err.retryable, false)
    end
  )

  t.it("ParameterOutOfRange is an InvalidParameter (errors.test.ts)", function()
    local Postgres = require("azure.postgresql")
    local message = "The value of the 'Version' should be in: [11,12,13,14,15,16,17,18]."
      .. " Verify that the specified parameter value is correct."
    local c = new(Postgres, { { status = 400, body = arm_error("ParameterOutOfRange", message) } })
    local _, err = c:servers_create_or_update({
      subscriptionId = SUB,
      resourceGroupName = "rg",
      serverName = "pg",
      location = "centralus",
    })
    t.eq(err.tag, "InvalidParameter")
    t.eq(err.code, "ParameterOutOfRange")
    t.eq(err.message, message)
  end)

  t.it("the token never appears in an error", function()
    local err = fail_with(401, arm_error("InvalidAuthenticationToken", "bad"))
    t.no_match(json.encode(err), TOKEN, true)
    t.no_match(tostring(err), TOKEN, true)
  end)
end)

t.describe("azure protocol: success decoding", function()
  t.it("the 2xx JSON body is the payload (protocol.test.ts)", function()
    local group = { id = "/x", name = "my-rg", location = "westus", tags = { env = "prod" } }
    local c = new(Resources, { ok(group) })
    local v = c:get_resource_group(rg)
    t.eq(json.encode(v), json.encode(group))
  end)

  t.it(
    "empty 202 / 204 / 200 bodies decode to the declared headers, or {} (protocol.test.ts)",
    function()
      local c = new(Resources, {
        { status = 202, body = "", headers = { location = "https://poll" } },
        { status = 204, body = "" },
        { status = 200, body = "" },
      })
      t.eq(json.encode(c:delete_resource_group(rg)), json.encode({ location = "https://poll" }))
      t.eq(json.encode(c:delete_resource_group(rg)), "{}")
      t.eq(json.encode(c:delete_resource_group(rg)), "{}")
    end
  )

  t.it("a 200 response whose body is JSON null returns null (protocol.test.ts)", function()
    local c = new(Resources, { { status = 200, body = "null" } })
    t.eq(c:delete_resource_group(rg), json.null)
  end)

  t.it("sensitive output members are delivered as secrets (protocol.test.ts)", function()
    local c = new(AppConfiguration, {
      ok({ id = "k", connectionString = "Endpoint=secret", readOnly = true }),
    })
    local key = c:regenerate_configuration_store_key({
      subscriptionId = SUB,
      resourceGroupName = "rg",
      configStoreName = "store",
      id = "k",
    })
    t.eq(key.id, "k")
    t.truthy(secret.is(key.connectionString))
    t.eq(secret.unwrap(key.connectionString), "Endpoint=secret")
  end)

  t.it(
    "strict validation fails a mismatched payload with AzureParseError (protocol.test.ts)",
    function()
      local c = new(Resources, { ok({ name = "rg" }) }, { extra = { validation = "strict" } })
      local v, err = c:get_resource_group(rg)
      t.fails_with("AzureParseError", v, err)
      t.eq(err.categories.ParseError, true)
    end
  )

  t.it(
    "a body cut off mid-secret fails in both modes without exposing it (protocol.test.ts)",
    function()
      for _, mode in ipairs({ "lenient", "strict" }) do
        local c = new(AppConfiguration, {
          { status = 200, body = '{"id":"k","connectionString":"' .. SECRET },
        }, { extra = { validation = mode } })
        local v, err = c:regenerate_configuration_store_key({
          subscriptionId = SUB,
          resourceGroupName = "rg",
          configStoreName = "store",
          id = "k",
        })
        t.fails_with("AzureParseError", v, err)
        t.eq(err.body, "[REDACTED]", mode)
        t.no_match(json.encode(err), SECRET, true)
      end
    end
  )

  t.it(
    "a 202 carries the long-running operation's status monitor (response-headers.test.ts)",
    function()
      local Postgres = require("azure.postgresql")
      local monitor = BASE .. "/subscriptions/" .. SUB .. "/providers/x/azureAsyncOperation/5d"
      local results = BASE .. "/subscriptions/" .. SUB .. "/providers/x/operationResults/5d"
      local c = new(Postgres, {
        {
          status = 202,
          headers = {
            ["content-type"] = "application/json",
            ["azure-asyncoperation"] = monitor,
            location = results,
            ["retry-after"] = "60",
          },
          body = json.encode({ operation = "UpsertServerManagementOperationV2" }),
        },
      })
      local out, err = c:update_server({
        subscriptionId = SUB,
        resourceGroupName = "rg",
        serverName = "pg",
        properties = { createMode = "Update", version = "17" },
      })
      t.eq(err, nil)
      t.eq(out.azureAsyncOperation, monitor)
      t.eq(out.location, results)
      t.eq(out.retryAfter, 60)
    end
  )
end)

t.describe("azure protocol: retries and credentials", function()
  t.it("a 429 is retried after its Retry-After, then succeeds", function()
    local c, host = new(Resources, {
      {
        status = 429,
        body = arm_error("SomeThrottle", "slow"),
        headers = { ["retry-after"] = "2" },
      },
      ok({ name = "my-rg" }),
    }, { retry = "default" })
    local v, err = c:get_resource_group(rg)
    t.eq(err, nil)
    t.eq(v.name, "my-rg")
    t.eq(#host.requests, 2)
    t.eq(host.sleeps[1], 2)
  end)

  t.it(
    "a code-mapped throttling error is retried with backoff (Distilled sets no retryAfter)",
    function()
      local c, host = new(Resources, {
        {
          status = 429,
          body = arm_error("TooManyRequests", "slow"),
          headers = { ["retry-after"] = "2" },
        },
        ok({ name = "my-rg" }),
      }, { retry = "default" })
      local v, err = c:get_resource_group(rg)
      t.eq(err, nil)
      t.eq(v.name, "my-rg")
      t.eq(#host.requests, 2)
      t.eq(#host.sleeps, 1)
      t.truthy(host.sleeps[1] < 2, "backoff, not the Retry-After")
    end
  )

  t.it("a conflict is not retried", function()
    local c, host = new(Resources, {
      { status = 409, body = arm_error("Conflict", "busy") },
    }, { retry = "default" })
    local v, err = c:get_resource_group(rg)
    t.fails_with("ResourceConflict", v, err)
    t.eq(#host.requests, 1)
  end)

  t.it("an expired token (401 Unauthorized) makes a function source resolve again", function()
    local n = { calls = 0 }
    local source = function()
      n.calls = n.calls + 1
      return "tok-" .. n.calls
    end
    local c, host = new(Resources, {
      { status = 401, body = arm_error("ExpiredAuthenticationToken", "The access token expired.") },
      ok({}),
    }, { bearer_token = source })
    local _, err = c:get_resource_group(rg)
    t.eq(err, nil)
    t.eq(host.requests[1].headers.authorization, "Bearer tok-1")
    t.eq(host.requests[2].headers.authorization, "Bearer tok-2")
  end)

  t.it("a function source is resolved once and reused while it works", function()
    local n = { calls = 0 }
    local c = new(Resources, { ok({}), ok({}) }, {
      bearer_token = function()
        n.calls = n.calls + 1
        return "tok"
      end,
    })
    c:get_resource_group(rg)
    c:get_resource_group(rg)
    t.eq(n.calls, 1)
  end)

  local function token_answer(access, expires_in)
    return { status = 200, body = json.encode({ access_token = access, expires_in = expires_in }) }
  end

  t.it(
    "exchanges Entra ID client credentials for a token and reuses it until near expiry",
    function()
      local c, host = new(Resources, {
        token_answer("entra-1", 3600),
        ok({}),
        ok({}),
        token_answer("entra-2", 3600),
        ok({}),
      }, {
        bearer_token = false,
        extra = { tenant_id = "tenant-1", client_id = "app-1", client_secret = secret.wrap(SECRET) },
      })
      t.eq(select(2, c:get_resource_group(rg)), nil)
      t.eq(select(2, c:get_resource_group(rg)), nil)
      local tok = host.requests[1]
      t.eq(tok.method, "POST")
      t.eq(tok.url, "https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token")
      t.eq(tok.headers["content-type"], "application/x-www-form-urlencoded")
      t.eq(
        tok.body,
        "client_id=app-1&client_secret="
          .. SECRET
          .. "&grant_type=client_credentials&scope=https%3A%2F%2Fmanagement.azure.com%2F.default"
      )
      t.eq(host.requests[2].headers.authorization, "Bearer entra-1")
      t.eq(host.requests[3].headers.authorization, "Bearer entra-1")
      -- 5 minutes before expiry the next request gets a new token
      host.advance(3600 - 300)
      t.eq(select(2, c:get_resource_group(rg)), nil)
      t.eq(host.requests[4].url, "https://login.microsoftonline.com/tenant-1/oauth2/v2.0/token")
      t.eq(host.requests[5].headers.authorization, "Bearer entra-2")
    end
  )

  t.it(
    "reads AZURE_CLIENT_ID / AZURE_CLIENT_SECRET / AZURE_TENANT_ID and AZURE_AUTHORITY_HOST",
    function()
      local c, host = new(Resources, { token_answer("entra-env", 3600), ok({}) }, {
        bearer_token = false,
        env = {
          AZURE_CLIENT_ID = "app-env",
          AZURE_CLIENT_SECRET = SECRET,
          AZURE_TENANT_ID = "tenant-env",
          AZURE_AUTHORITY_HOST = "https://login.microsoftonline.us/",
        },
      })
      t.eq(select(2, c:get_resource_group(rg)), nil)
      t.eq(host.requests[1].url, "https://login.microsoftonline.us/tenant-env/oauth2/v2.0/token")
      t.eq(host.requests[2].headers.authorization, "Bearer entra-env")
    end
  )

  t.it("a refused client secret is a ConfigError without the secret; ARM is not called", function()
    local c, host = new(Resources, {
      {
        status = 401,
        body = json.encode({ error = "invalid_client", error_description = "AADSTS7000215" }),
      },
    }, {
      bearer_token = false,
      extra = { tenant_id = "t", client_id = "app", client_secret = SECRET },
    })
    local v, err = c:get_resource_group(rg)
    t.fails_with("ConfigError", v, err)
    t.match(err.message, "invalid_client", true)
    t.no_match(json.encode(err), SECRET, true)
    t.eq(#host.requests, 1)
  end)

  t.it("the generated clients carry the protocol's own provider data (azure.PROVIDER)", function()
    local text = assert(io.open(t.root .. "/clients/azure/resources/init.lua", "rb")):read("*a")
    for name in pairs(azure.PROVIDER.options) do
      t.match(text, "      " .. name .. " = {", true)
    end
    t.match(text, azure.PROVIDER.oauth.token_url, true)
  end)
end)
