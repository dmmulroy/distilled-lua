-- The generated Scaleway clients (clients/scaleway/) over the scripted transport: what
-- Distilled's ScalewayProtocol (packages/scaleway/src/protocol.ts), errors.ts and
-- pagination.ts do. No network.
local t = require("spec.harness")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local KEY = "11111111-2222-3333-4444-SPECFAKEKEY0"

local function client(module, opts, responses)
  local host = testing.host({ responses = responses or {}, env = opts.env or {} })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  return require(module).new(o), host
end

local function server(id)
  return { id = id, name = "s-" .. id }
end

t.describe("scaleway: requests", function()
  t.it("X-Auth-Token; a missing {zone} is the zone option's default fr-par-1", function()
    local c, host = client("scaleway.instance_v1", { env = { SCW_SECRET_KEY = KEY } }, {
      { status = 200, body = { server = server("a") } },
    })
    local _, err = c:get_server({ server_id = "a" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.url, "https://api.scaleway.com/instance/v1/zones/fr-par-1/servers/a")
    t.eq(req.headers["x-auth-token"], KEY)
    t.eq(req.headers.authorization, nil)
  end)

  t.it("SCW_DEFAULT_ZONE / SCW_DEFAULT_REGION, and an explicit label wins", function()
    local c, host = client("scaleway.instance_v1", {
      secret_key = KEY,
      env = { SCW_DEFAULT_ZONE = "nl-ams-1" },
    }, { { status = 200, body = {} }, { status = 200, body = {} } })
    c:get_server({ server_id = "a" })
    c:get_server({ server_id = "a", zone = "pl-waw-2" })
    t.eq(host.requests[1].url, "https://api.scaleway.com/instance/v1/zones/nl-ams-1/servers/a")
    t.eq(host.requests[2].url, "https://api.scaleway.com/instance/v1/zones/pl-waw-2/servers/a")
    local k8s, h2 = client("scaleway.k8s_v1", {
      secret_key = KEY,
      env = { SCW_DEFAULT_REGION = "nl-ams" },
    }, { { status = 200, body = { clusters = {}, total_count = 0 } } })
    k8s:list_clusters({ region = "" })
    t.match(h2.requests[1].url, "^https://api%.scaleway%.com/k8s/v1/regions/nl%-ams/clusters")
  end)

  t.it("SCW_API_URL moves api.scaleway.com operations only; Generative APIs get Bearer", function()
    local env = { SCW_SECRET_KEY = KEY, SCW_API_URL = "https://proxy.test/" }
    local c, host = client("scaleway.instance_v1", { env = env }, { { status = 200, body = {} } })
    c:get_server({ server_id = "a" })
    t.eq(host.requests[1].url, "https://proxy.test/instance/v1/zones/fr-par-1/servers/a")
    local g, gh = client("scaleway.generative_apis_openai_v1", { env = env }, {
      { status = 200, body = { id = "b1" } },
    })
    local _, err = g:get_batch({ project_id = "p1", batch_id = "b1" })
    t.eq(err, nil)
    t.eq(gh.requests[1].url, "https://api.scaleway.ai/p1/v1/batches/b1")
    t.eq(gh.requests[1].headers.authorization, "Bearer " .. KEY)
    t.eq(gh.requests[1].headers["x-auth-token"], KEY)
  end)

  t.it("a ...Raw download asks for the file (dl=1) and returns its bytes", function()
    local c, host = client("scaleway.account_contract_v3", { secret_key = KEY }, {
      { status = 200, headers = { ["content-type"] = "application/pdf" }, body = "%PDF-1.7\0\255" },
    })
    local bytes, err = c:download_contract_signature_raw({ contract_signature_id = "cs1" })
    t.eq(err, nil)
    t.eq(bytes, "%PDF-1.7\0\255")
    t.eq(
      host.requests[1].url,
      "https://api.scaleway.com/account/v3/contract-signatures/cs1/download?dl=1"
    )
  end)

  t.it("no secret key is a ConfigError naming SCW_SECRET_KEY", function()
    local c = client("scaleway.instance_v1", {})
    local _, err = c:get_server({ server_id = "a" })
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "SCW_SECRET_KEY", true)
  end)
end)

t.describe("scaleway: answers", function()
  t.it("drops nulls and folds X-Total-Count into total_count", function()
    local c = client("scaleway.instance_v1", { secret_key = KEY }, {
      {
        status = 200,
        headers = { ["x-total-count"] = "7" },
        body = {
          servers = { { id = "a", name = "x", ipv6 = { address = "::1", gateway = "null" } } },
        },
      },
    })
    local res, err = c:list_servers({})
    t.eq(err, nil)
    t.eq(res.total_count, 7)
    t.eq(res.servers[1].id, "a")
  end)

  t.it("null members are dropped, list items kept", function()
    local c = client("scaleway.instance_v1", { secret_key = KEY }, {
      { status = 200, body = '{"server":{"id":"a","name":null,"tags":["x",null]}}' },
    })
    local res = c:get_server({ server_id = "a" })
    t.eq(res.server.id, "a")
    t.eq(rawget(res.server, "name"), nil)
    t.eq(#res.server.tags, 2)
  end)

  t.it("pages by total_count, sized by the first page (paginateByTotalCount)", function()
    local c, host = client("scaleway.instance_v1", { secret_key = KEY }, {
      { status = 200, body = { servers = { server("1"), server("2") }, total_count = 5 } },
      { status = 200, body = { servers = { server("3"), server("4") }, total_count = 5 } },
      { status = 200, body = { servers = { server("5") }, total_count = 5 } },
    })
    local items, err = c:list_servers_items({ per_page = 2 }):collect()
    t.eq(err, nil)
    t.eq(#items, 5)
    t.eq(items[5].id, "5")
    t.eq(#host.requests, 3, "ceil(5 / 2) pages, then stop")
    t.match(host.requests[1].url, "page=1", true)
    t.match(host.requests[3].url, "page=3", true)
  end)

  t.it("stops on an empty page, and after one page without a total", function()
    local c, host = client("scaleway.instance_v1", { secret_key = KEY }, {
      { status = 200, body = { servers = { server("1") }, total_count = 10 } },
      { status = 200, body = { servers = {}, total_count = 10 } },
    })
    local items = c:list_servers_items({}):collect()
    t.eq(#items, 1)
    t.eq(#host.requests, 2)
    local c2, h2 = client("scaleway.instance_v1", { secret_key = KEY }, {
      { status = 200, body = { servers = { server("1") } } },
    })
    t.eq(#c2:list_servers_items({}):collect(), 1)
    t.eq(#h2.requests, 1)
  end)
end)

t.describe("scaleway: failures by body.type (errors.ts)", function()
  local function fail(body, status, headers)
    local c = client("scaleway.instance_v1", { secret_key = KEY }, {
      { status = status, headers = headers, body = body },
    })
    local _, err = c:get_server({ server_id = "a" })
    return err
  end

  t.it("invalid_arguments: details, and each argument's help in the message", function()
    local err = fail({
      type = "invalid_arguments",
      message = "invalid argument(s)",
      details = {
        { argument_name = "name", reason = "required", help_message = "name is required" },
        { argument_name = "x" },
      },
    }, 400)
    t.eq(err.tag, "InvalidArgumentsError")
    t.eq(err.message, "invalid argument(s) (name: name is required; x: invalid)")
    t.eq(#err.details, 1)
    t.eq(err.details[1].reason, "required")
    t.truthy(err.categories.BadRequestError)
  end)

  t.it("transient_state is a retryable conflict; not_found keeps resource fields", function()
    local err = fail({
      type = "transient_state",
      message = "resource is in a transient state",
      resource = "instance_server",
      resource_id = "a",
      current_state = "starting",
    }, 409)
    t.eq(err.tag, "TransientStateError")
    t.eq(err.retryable, true)
    t.eq(err.current_state, "starting")
    err = fail({ type = "not_found", resource = "instance_server", resource_id = "a" }, 404)
    t.eq(err.tag, "ResourceNotFoundError")
    t.eq(err.message, "not_found")
    t.eq(err.resource_id, "a")
  end)

  t.it("too_many_requests: Retry-After, else reset_seconds", function()
    local err = fail({ type = "too_many_requests", message = "slow down", reset_seconds = 12 }, 429)
    t.eq(err.tag, "TooManyRequests")
    t.eq(err.retry_after, 12)
    err = fail(
      { type = "too_many_requests", message = "slow down", reset_seconds = 12 },
      429,
      { ["retry-after"] = "3" }
    )
    t.eq(err.retry_after, 3)
  end)

  t.it("legacy unknown_resource names the missing UUID", function()
    local err = fail({
      type = "unknown_resource",
      message = "Security group '0b5d5f5e-1111-2222-3333-444455556666' not found",
    }, 404)
    t.eq(err.tag, "ResourceNotFoundError")
    t.eq(err.resource, "security_group")
    t.eq(err.resource_id, "0b5d5f5e-1111-2222-3333-444455556666")
  end)

  t.it("legacy invalid_request_error: quota text, then per-field messages", function()
    local err = fail({
      type = "invalid_request_error",
      message = "Quota exceeded for this resource.",
      resource = "instance",
    }, 403)
    t.eq(err.tag, "QuotasExceededError")
    err = fail({
      type = "invalid_request_error",
      message = "Validation Error",
      fields = { name = { "too long", "bad" } },
    }, 400)
    t.eq(err.tag, "InvalidArgumentsError")
    t.eq(#err.details, 2)
    err = fail({ type = "invalid_request_error", message = "Nope" }, 400)
    t.eq(err.tag, "BadRequest")
  end)

  t.it("no known type: the status class, then UnknownScalewayError with the type", function()
    local err = fail({ type = "something_new", message = "hm" }, 404)
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "hm")
    err = fail({ type = "something_new", message = "hm" }, 418)
    t.eq(err.tag, "UnknownScalewayError")
    t.eq(err.code, "something_new")
    t.truthy(err.categories.ServerError)
    err = fail("<html>bad gateway</html>", 502)
    t.eq(err.tag, "BadGateway")
    t.no_match(err.message, KEY, true)
  end)
end)
