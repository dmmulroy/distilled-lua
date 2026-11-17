-- The provider specs in providers/*.lua (task 13): each loads and validates, and the
-- representative ones behave like Distilled's hand-written glue they mirror, through a
-- client generated from the fixture model (verify/lib/gen_fixture.lua) with the real
-- spec. Glue-only behaviour (per-route base URLs, envelopes) is tested on the glue
-- module directly.
local t = require("spec.harness")
local compat = require("distilled.compat")
local errors = require("distilled.errors")
local fx = require("verify.lib.gen_fixture")
local json = require("distilled.json")
local provider = require("distilled.gen.provider")
local testing = require("distilled.testing")

local function must(v, err)
  if v == nil then
    t.fail("expected a value, got error: " .. t.show(err))
  end
  return v
end

local function path_of(name)
  return t.root .. "/providers/" .. name .. ".lua"
end

-- the generated client of the fixture model with providers/<name>.lua
local built = {}
local function class_of(name)
  if built[name] then
    return built[name]
  end
  local files, err = fx.generate({ provider = path_of(name) })
  if not files then
    t.fail("generate with providers/" .. name .. ".lua: " .. tostring(err))
  end
  local svc = fx.load(files["service.lua"], "ex.service")
  local modules = { ["ex.service"] = svc }
  if files["glue.lua"] then
    modules["ex.glue"] = fx.load(files["glue.lua"], "ex.glue")
  end
  local class = fx.load(files["init.lua"], "ex", modules)
  built[name] = { class = class, files = files }
  return built[name]
end

local function json_response(body, status, headers)
  local h = { ["content-type"] = "application/json" }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  return {
    status = status or 200,
    headers = h,
    body = type(body) == "string" and body or json.encode(body),
  }
end

local THING = { thing = { id = "t1" } }

-- client(name, { env, options, responses }) -> client, host
local function client(name, opts)
  opts = opts or {}
  local host =
    testing.host({ env = opts.env or {}, responses = opts.responses or { json_response(THING) } })
  local options = { host = host, retry = "none" }
  for k, v in pairs(opts.options or {}) do
    options[k] = v
  end
  return class_of(name).class.new(options), host
end

-- a glue module as the generator copies it
local function glue(name)
  local f = assert(io.open(t.root .. "/providers/glue/" .. name .. ".lua", "rb"))
  local text = f:read("*a")
  f:close()
  local chunk = assert(compat.load(text, "@glue/" .. name .. ".lua"))
  return chunk("glue")
end

-- every providers/*.lua, kept here because gopher-lua cannot list a directory; the
-- first case checks it against the directory where io.popen works
local NAMES = {
  "adyen",
  "anthropic",
  "apache_superset",
  "archil",
  "argocd",
  "auth0",
  "aws", -- task 17 (gen/aws.lua)
  "axiom",
  "boat_dev",
  "boxd",
  "celld",
  "chronosphere",
  "clerk",
  "clickhouse_cloud",
  "coinflow",
  "convex",
  "coolify",
  "customerio",
  "datadog",
  "daytona",
  "digitalocean",
  "discord",
  "docker",
  "dokploy",
  "doppler",
  "e2b",
  "elasticsearch",
  "entire",
  "exa",
  "fly_io",
  "forgejo",
  "gcp", -- task 21 (discovery spec)
  "github",
  "google_workspace", -- task 21 (discovery spec)
  "grafana",
  "growthbook",
  "gusto",
  "hetzner",
  "hostinger",
  "huggingface",
  "hydradb",
  "iceberg",
  "infisical",
  "inngest",
  "intercom",
  "kubernetes",
  "launchdarkly",
  "mailchimp",
  "meilisearch",
  "mercury",
  "metabase",
  "modal",
  "modrinth",
  "mongodb_atlas",
  "namespacelabs",
  "neon",
  "netbird",
  "notion",
  "npm",
  "okta",
  "onepassword",
  "opencode",
  "opensearch",
  "ovh",
  "paypal",
  "plaid",
  "planetscale",
  "polar",
  "porkbun",
  "posthog",
  "prisma",
  "proxmox",
  "questrade",
  "redis_cloud",
  "remote",
  "render",
  "resend",
  "revenuecat",
  "rivet",
  "s2",
  "s3",
  "scaleway",
  "sentry",
  "slack",
  "spacetimedb",
  "squarespace",
  "stackit",
  "starburst_galaxy",
  "steel",
  "stripe",
  "supabase",
  "surrealdb",
  "tailscale",
  "technitium",
  "temporal",
  "tencentcloud", -- task 22 (rpc spec)
  "trigger_dev",
  "turbopuffer",
  "turso",
  "typesense",
  "unkey",
  "vanta",
  "vercel",
  "whop",
  "workos",
  "xata",
  "zendesk",
  "zerossl",
}

t.describe("providers: every spec loads", function()
  t.it("the list names every file in providers/ (lua and luajit only)", function()
    local ok, listing = compat.pcall(function()
      local f = io.popen('ls "' .. t.root .. '/providers"')
      local text = f:read("*a")
      f:close()
      return text
    end)
    if not ok then
      return -- gopher-lua: io.popen raises
    end
    local on_disk = {}
    for file in string.gmatch(listing, "([%w_]+)%.lua") do
      -- GraphQL-only packages (task 16: linear, railway, expo_eas) are specs of the
      -- GraphQL generator, checked in spec/graphql_*_spec.lua
      local spec = dofile(path_of(file))
      if not (type(spec) == "table" and spec.graphql ~= nil and spec.base_url == nil) then
        on_disk[#on_disk + 1] = file
      end
    end
    t.same(on_disk, NAMES)
  end)

  t.it("each providers/*.lua validates (glue included)", function()
    t.truthy(#NAMES >= 90, "provider list has " .. #NAMES .. " entries")
    for _, name in ipairs(NAMES) do
      local spec, err = provider.load(path_of(name))
      t.truthy(spec, tostring(name) .. ": " .. tostring(err))
      t.eq(spec.name, name)
    end
  end)
end)

t.describe("providers: options, env lists and headers through a generated client", function()
  t.it("datadog: DD_SITE templates the base URL; DD-APPLICATION-KEY only when set", function()
    local c, host = client("datadog", { env = { DD_API_KEY = "k", DD_SITE = "datadoghq.eu" } })
    must(c:get_thing({ thing_id = "x" }))
    local r = host.requests[1]
    t.eq(r.url, "https://api.datadoghq.eu/things/x")
    t.eq(r.headers["dd-api-key"], "k")
    t.eq(r.headers["dd-application-key"], nil)
    local c2, host2 = client("datadog", { env = { DD_API_KEY = "k", DD_APP_KEY = "app" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].url, "https://api.datadoghq.com/things/x")
    t.eq(host2.requests[1].headers["dd-application-key"], "app")
  end)

  t.it("anthropic: x-api-key and anthropic-version (ANTHROPIC_VERSION overrides)", function()
    local c, host =
      client("anthropic", { env = { ANTHROPIC_API_KEY = "sk", ANTHROPIC_VERSION = "2099-01-01" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers["x-api-key"], "sk")
    t.eq(host.requests[1].headers["anthropic-version"], "2099-01-01")
    local c2, host2 = client("anthropic", { env = { ANTHROPIC_API_KEY = "sk" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].headers["anthropic-version"], "2026-10-21")
  end)

  t.it("anthropic: 529 is ServiceUnavailable", function()
    local c = client("anthropic", {
      env = { ANTHROPIC_API_KEY = "sk" },
      responses = {
        json_response({ error = { type = "overloaded_error", message = "Overloaded" } }, 529),
      },
    })
    local err = t.fails_with("ServiceUnavailable", c:get_thing({ thing_id = "x" }))
    t.eq(err.message, "Overloaded")
    t.eq(err.code, "overloaded_error")
  end)

  t.it("sentry: the first set variable of each list wins", function()
    local c, host = client("sentry", {
      env = { SENTRY_API_KEY = "k2", SENTRY_API_BASE_URL = "https://sentry.example.com" },
    })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://sentry.example.com/things/x")
    t.eq(host.requests[1].headers.authorization, "Bearer k2")
    local c2 = client("sentry", { env = {} })
    local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
    t.match(err.message, "SENTRY_AUTH_TOKEN (or SENTRY_API_KEY)", true)
  end)

  t.it("npm: an optional token is left out when unset", function()
    local c, host = client("npm", { env = { NPM_API_BASE_URL = "https://npm.example.com//" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers.authorization, nil)
    t.eq(host.requests[1].url, "https://npm.example.com/things/x")
  end)

  t.it(
    "okta: the scheme is SSWS unless OKTA_AUTH_SCHEME is Bearer; the org URL is required",
    function()
      local cases =
        { { nil, "SSWS" }, { "Bearer", "Bearer" }, { "bearer", "SSWS" }, { "SSWS", "SSWS" } }
      for _, case in ipairs(cases) do
        local c, host = client("okta", {
          env = {
            OKTA_API_TOKEN = "tok",
            OKTA_ORG_URL = "https://acme.okta.com/",
            OKTA_AUTH_SCHEME = case[1],
          },
        })
        must(c:get_thing({ thing_id = "x" }))
        t.eq(host.requests[1].headers.authorization, case[2] .. " tok", tostring(case[1]))
        t.eq(host.requests[1].url, "https://acme.okta.com/things/x")
      end
      local c, host = client("okta", { env = { OKTA_API_TOKEN = "tok" } })
      local err = t.fails_with("ConfigError", c:get_thing({ thing_id = "x" }))
      t.match(err.message, "OKTA_ORG_URL", true)
      t.eq(#host.requests, 0)
    end
  )

  t.it("coinflow: COINFLOW_ENV picks the base URL; another value is a ConfigError", function()
    local c, host =
      client("coinflow", { env = { COINFLOW_API_KEY = "k", COINFLOW_ENV = "production" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://api.coinflow.cash/api/things/x")
    t.eq(host.requests[1].headers.authorization, "k")
    local c2, host2 =
      client("coinflow", { env = { COINFLOW_API_KEY = "k", COINFLOW_ENV = "prod" } })
    local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
    t.match(err.message, "must be one of production, sandbox", true)
    t.eq(#host2.requests, 0)
  end)

  t.it("ovh: an unknown OVH_ENDPOINT is the default endpoint", function()
    local c, host = client("ovh", { env = { OVH_ACCESS_TOKEN = "k", OVH_ENDPOINT = "ovh-ca" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://ca.api.ovh.com/1.0/things/x")
    local c2, host2 = client("ovh", { env = { OVH_ACCESS_TOKEN = "k", OVH_ENDPOINT = "mars" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].url, "https://eu.api.ovh.com/1.0/things/x")
  end)

  t.it("auth0: the domain loses its scheme and slashes; without it nothing is sent", function()
    local c, host = client("auth0", {
      env = { AUTH0_MANAGEMENT_TOKEN = "t", AUTH0_DOMAIN = "https://acme.eu.auth0.com/" },
    })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://acme.eu.auth0.com/api/v2/things/x")
    local c2, host2 = client("auth0", { env = { AUTH0_MANAGEMENT_TOKEN = "t" } })
    local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
    t.eq(err.key, "domain")
    t.eq(#host2.requests, 0)
  end)

  t.it("forgejo: token prefix and /api/v1 appended once", function()
    local c, host =
      client("forgejo", { env = { FORGEJO_TOKEN = "t", FORGEJO_URL = "https://codeberg.org/" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://codeberg.org/api/v1/things/x")
    t.eq(host.requests[1].headers.authorization, "token t")
  end)

  t.it("netbird: a base URL with a path is a ConfigError naming the NetBird rule", function()
    local c, host = client("netbird", {
      env = { NETBIRD_API_TOKEN = "t", NETBIRD_API_URL = "https://nb.example.com/api" },
    })
    local err = t.fails_with("ConfigError", c:get_thing({ thing_id = "x" }))
    t.match(err.message, "NetBird API base URL must be an origin", true)
    t.eq(#host.requests, 0)
    local c2, host2 = client("netbird", { env = { NETBIRD_API_TOKEN = "t" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].url, "https://api.netbird.io/things/x")
    t.eq(host2.requests[1].headers.authorization, "Token t")
  end)

  t.it("planetscale: a service token or an OAuth access token", function()
    local env = {
      PLANETSCALE_API_TOKEN_ID = "id",
      PLANETSCALE_API_TOKEN = "tok",
      PLANETSCALE_ORGANIZATION = "org",
    }
    local c, host = client("planetscale", { env = env })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers.authorization, "id:tok")
    local c2, host2 = client("planetscale", {
      env = { PLANETSCALE_ORGANIZATION = "org" },
      options = { access_token = "oauth" },
    })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].headers.authorization, "Bearer oauth")
    local c3 = client("planetscale", { env = { PLANETSCALE_ORGANIZATION = "org" } })
    t.fails_with("ConfigError", c3:get_thing({ thing_id = "x" }))
  end)

  t.it("clickhouse_cloud: Basic key id and secret; { result } is unwrapped", function()
    local c, host = client("clickhouse_cloud", {
      env = { CLICKHOUSE_CLOUD_API_KEY_ID = "id", CLICKHOUSE_CLOUD_API_KEY_SECRET = "sec" },
      responses = { json_response({ status = 200, requestId = "r", result = THING }) },
    })
    local out = must(c:get_thing({ thing_id = "x" }))
    t.eq(out.thing.id, "t1")
    t.eq(host.requests[1].headers.authorization, "Basic aWQ6c2Vj")
  end)

  t.it("opencode: Basic only when a password is set; the username defaults to opencode", function()
    local c, host = client("opencode", {})
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers.authorization, nil)
    local c2, host2 = client("opencode", { env = { OPENCODE_SERVER_PASSWORD = "pw" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].headers.authorization, "Basic b3BlbmNvZGU6cHc=")
  end)

  t.it("modrinth and github: the provider's User-Agent, overridable by env and option", function()
    local c, host = client("modrinth", {})
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers["user-agent"], "distilled.cloud-modrinth")
    local c2, host2 = client("github", { env = { GH_TOKEN = "g", GITHUB_USER_AGENT = "me/1" } })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].headers["user-agent"], "me/1")
    t.eq(host2.requests[1].headers.authorization, "Bearer g")
    t.eq(host2.requests[1].headers["x-github-api-version"], "2022-11-28")
    t.eq(host2.requests[1].headers.accept, "application/vnd.github+json")
    local c3, host3 =
      client("github", { env = { GH_TOKEN = "g" }, options = { user_agent = "mine" } })
    must(c3:get_thing({ thing_id = "x" }))
    t.eq(host3.requests[1].headers["user-agent"], "mine")
  end)

  t.it("doppler: public operations need no token", function()
    -- the fixture has no AuthOidc; the spec's public_operations are checked against the
    -- Doppler model by the generator (gen/init.lua)
    local spec = must(provider.load(path_of("doppler")))
    t.same(spec.runtime.anonymous, {
      AuthOidc = true,
      GenerateCliAuth = true,
      AuthorizeCliAuth = true,
      RevokeCliAuth = true,
    })
  end)
end)

t.describe("providers: error classes, envelopes and unknown fields", function()
  t.it("vercel: 402 PaymentRequired (quota), 410 Gone (not found), { error } envelope", function()
    local c = client("vercel", {
      env = { VERCEL_TOKEN = "v" },
      responses = {
        json_response({ error = { code = "payment_required", message = "Pay" } }, 402),
        json_response({ error = { code = "gone", message = "Old API" } }, 410),
      },
    })
    local err = t.fails_with("PaymentRequired", c:get_thing({ thing_id = "x" }))
    t.eq(err.code, "payment_required")
    t.eq(err.message, "Pay")
    t.truthy(errors.has_category(err, "QuotaError"))
    local gone = t.fails_with("Gone", c:get_thing({ thing_id = "x" }))
    t.truthy(errors.has_category(gone, "NotFoundError"))
    t.falsy(gone.retryable)
  end)

  t.it("s2: 408 RequestTimeout is retryable", function()
    local c =
      client("s2", { env = { S2_ACCESS_TOKEN = "s" }, responses = { json_response({}, 408) } })
    local err = t.fails_with("RequestTimeout", c:get_thing({ thing_id = "x" }))
    t.truthy(err.retryable)
  end)

  t.it("kubernetes: the unknown error carries the Status reason", function()
    local c = client("kubernetes", {
      env = { KUBERNETES_TOKEN = "k", KUBERNETES_API_URL = "https://k8s.test" },
      responses = {
        json_response({ kind = "Status", reason = "Expired", message = "too old" }, 410),
      },
    })
    local err = t.fails_with("UnknownKubernetesError", c:get_thing({ thing_id = "x" }))
    t.eq(err.reason, "Expired")
    t.eq(err.message, "too old")
  end)

  t.it("customerio: the first text value of each pointer list", function()
    local c = client("customerio", {
      env = { CUSTOMERIO_API_KEY = "c" },
      responses = { json_response({ meta = { errors = { "email is invalid" } } }, 400) },
    })
    t.eq(t.fails_with("BadRequest", c:get_thing({ thing_id = "x" })).message, "email is invalid")
  end)

  t.it("github: a 403 rate limit is TooManyRequests waiting until x-ratelimit-reset", function()
    local host = testing.host({
      env = { GITHUB_TOKEN = "g" },
      responses = {
        json_response({ message = "API rate limit exceeded" }, 403, {
          ["x-ratelimit-remaining"] = "0",
          ["x-ratelimit-reset"] = tostring(1700000000 + 30),
        }),
        json_response({ message = "Must have admin rights" }, 403),
        json_response({ message = "You have exceeded a secondary rate limit" }, 403),
      },
    })
    local c = class_of("github").class.new({ host = host, retry = "none" })
    local err = t.fails_with("TooManyRequests", c:get_thing({ thing_id = "x" }))
    t.eq(err.retry_after, 30)
    t.fails_with("Forbidden", c:get_thing({ thing_id = "x" }))
    t.eq(t.fails_with("TooManyRequests", c:get_thing({ thing_id = "x" })).retry_after, 60)
  end)

  t.it("zerossl: success = 0 in a 200 is a failure; success = 1 decodes", function()
    local c = client("zerossl", {
      env = { ZERO_SSL_KEY = "z" },
      responses = {
        json_response({
          success = 0,
          error = { code = 2800, type = "invalid_access_key", info = "Bad key" },
        }),
        json_response({ success = 1, thing = { id = "t1" } }),
      },
    })
    local err = t.fails_with("UnknownZeroSslError", c:get_thing({ thing_id = "x" }))
    t.eq(err.message, "Bad key")
    t.eq(err.status, 200)
    local out = must(c:get_thing({ thing_id = "x" }))
    t.eq(out.thing.id, "t1")
  end)

  t.it("supabase: 'active free projects' is FreeProjectLimitReached, 406 is NotFound", function()
    local c = client("supabase", {
      env = { SUPABASE_ACCESS_TOKEN = "s" },
      responses = {
        json_response({
          message = "The following organization members have reached their maximum limits for the number of active free projects",
        }, 400),
        json_response({ message = "nope" }, 406),
      },
    })
    local err = t.fails_with("FreeProjectLimitReached", c:get_thing({ thing_id = "x" }))
    t.truthy(errors.has_category(err, "QuotaError"))
    t.fails_with("NotFound", c:get_thing({ thing_id = "x" }))
  end)

  t.it("entire: detail plus located field errors, joined by '; '", function()
    local env = glue("entire").error_envelope
    t.same(
      env(
        json.decode(
          '{"title":"Bad","detail":"invalid body","errors":[{"location":"body.name","message":"required"},{"message":"x"},{"location":"q"}]}'
        )
      ),
      { code = "Bad", message = "invalid body; body.name: required; x" }
    )
    t.same(env(json.decode('{"code":"","title":"T"}')), { code = "T", message = "T" })
    t.same(env(json.decode("{}")), {})
  end)

  t.it("proxmox: field errors under the message, trimmed and sorted", function()
    local env = glue("proxmox").error_envelope
    t.same(
      env(
        json.decode(
          '{"message":"Parameter verification failed. \\n","errors":{"vmid":" invalid ","name":"bad"}}'
        )
      ),
      { message = "Parameter verification failed.\nname: bad\nvmid: invalid" }
    )
    t.same(
      env(json.decode('{"errors":{"a":"b"}}')),
      { message = "Parameter verification failed.\na: b" }
    )
    t.same(env(json.decode('{"message":" m "}')), { message = "m" })
  end)

  t.it("celld, rivet, mailchimp envelopes", function()
    t.same(
      glue("celld").error_envelope(
        json.decode('{"ok":false,"error":{"kind":"NotFound","reason":"no cell"}}')
      ),
      {
        message = "NotFound: no cell",
      }
    )
    t.same(
      glue("celld").error_envelope(json.decode('{"error":"e","code":3}')),
      { code = 3, message = "e" }
    )
    t.same(
      glue("rivet").error_envelope(
        json.decode('{"group":"actor","code":"not_found","message":"m"}')
      ),
      {
        code = "actor.not_found",
        message = "m",
      }
    )
    t.same(
      glue("mailchimp").error_envelope(
        json.decode(
          '{"title":"Invalid Resource","detail":"Bad","errors":[{"field":"email","message":"invalid"},{"message":"other"}]}'
        )
      ),
      { message = "Bad (email: invalid; other)" }
    )
  end)
end)

t.describe("providers: glue settings and per-route base URLs", function()
  t.it("s2: /streams routes use the basin endpoint and need a basin", function()
    local base_url = glue("s2").base_url
    local s =
      { basin_endpoint = "https://{basin}.b.s2.dev/v1", account_endpoint = "https://a.s2.dev/v1" }
    t.eq(base_url(s, { uri = "/basins" }), "https://a.s2.dev/v1")
    t.eq(base_url(s, { uri = "/streamsx" }), "https://a.s2.dev/v1")
    local url, err = base_url(s, { uri = "/streams/{stream}/records" })
    t.eq(url, nil)
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "S2_BASIN", true)
    s.basin = "my%basin"
    t.eq(base_url(s, { uri = "/streams" }), "https://my%basin.b.s2.dev/v1")
  end)

  t.it("daytona: analytics, toolbox and API routes", function()
    local base_url = glue("daytona").base_url
    local s = {
      base_url = "https://app.daytona.io/api",
      analytics_base_url = "https://analytics.app.daytona.io",
      toolbox_base_url = "https://proxy.app.daytona.io/toolbox/{sandboxId}",
    }
    t.eq(
      base_url(s, { uri = "/organization/{organizationId}/usage" }),
      "https://analytics.app.daytona.io"
    )
    t.eq(base_url(s, { uri = "/sandbox" }), "https://app.daytona.io/api")
    local url, err = base_url(s, { uri = "/files/download" })
    t.eq(url, nil)
    t.match(err.message, "DAYTONA_SANDBOX_ID", true)
    s.sandbox_id = "sb-1"
    t.eq(base_url(s, { uri = "/files/download" }), "https://proxy.app.daytona.io/toolbox/sb-1")
  end)

  t.it("iceberg: <uri>/v1 plus the trimmed prefix, except /config", function()
    local base_url = glue("iceberg").base_url
    local s = { uri = "https://catalog.test/", prefix = "/ws/main/" }
    t.eq(base_url(s, { uri = "/config" }), "https://catalog.test/v1")
    t.eq(base_url(s, { uri = "/namespaces" }), "https://catalog.test/v1/ws/main")
    t.eq(
      base_url({ uri = "https://catalog.test" }, { uri = "/namespaces" }),
      "https://catalog.test/v1"
    )
    local url, err = base_url({}, { uri = "/namespaces" })
    t.eq(url, nil)
    t.eq(err.key, "uri")
  end)

  t.it("inngest: /v1/ routes use the origin of the base URL", function()
    local base_url = glue("inngest").base_url
    t.eq(base_url({}, { uri = "/v1/events" }), "https://api.inngest.com")
    t.eq(base_url({}, { uri = "/envs" }), "https://api.inngest.com/v2")
    t.eq(
      base_url({ base_url = "http://localhost:8288/v2" }, { uri = "/v1/x" }),
      "http://localhost:8288"
    )
  end)

  t.it("namespacelabs: the host by the service package prefix", function()
    local base_url = glue("namespacelabs").base_url
    local s =
      { region = "eu", private_api_base_url = "https://private-api.global.namespaceapis.com" }
    t.eq(
      base_url(s, { uri = "/namespace.cloud.compute.v1beta.ComputeService/CreateInstance" }),
      "https://eu.compute.namespaceapis.com"
    )
    t.eq(
      base_url(s, { uri = "/namespace.cloud.storage.v1/List" }),
      "https://eu.storage.namespaceapis.com"
    )
    t.eq(
      base_url(s, { uri = "/namespace.private.x/Y" }),
      "https://private-api.global.namespaceapis.com"
    )
    t.eq(base_url(s, { uri = "/namespace.cloud.iam.v1/Z" }), "https://global.namespaceapis.com")
    s.compute_base_url = "https://compute.test"
    t.eq(base_url(s, { uri = "/namespace.cloud.builder.v1/B" }), "https://compute.test")
  end)

  t.it("stackit: the server's {region}, a glued region, the api host rewrite, global", function()
    local base_url = glue("stackit").base_url
    local function at(server, region)
      return base_url({ region = region }, { uri = "/x", base_url = server })
    end
    t.eq(at("https://dns.api.stackit.cloud", "eu01"), "https://dns.api.eu01.stackit.cloud")
    t.eq(at("https://dns.api.stackit.cloud/v1", "global"), "https://dns.api.stackit.cloud/v1")
    t.eq(at("https://alb.api.{region}stackit.cloud", "eu01"), "https://alb.api.eu01.stackit.cloud")
    t.eq(at("https://alb.api.{region}.stackit.cloud", "eu02"), "https://alb.api.eu02.stackit.cloud")
    t.eq(at("https://alb.api.{region}stackit.cloud", "global"), "https://alb.api.stackit.cloud")
    t.eq(at("https://other.example.com", "eu01"), "https://other.example.com")
    t.eq(
      base_url({ base_url = "https://mock.test", region = "eu01" }, { uri = "/x" }),
      "https://mock.test"
    )
    local url, err = base_url({ region = "eu01" }, { uri = "/x" })
    t.eq(url, nil)
    t.eq(err.tag, "ConfigError")
  end)

  t.it("digitalocean: the operation's server picks inference or actions", function()
    local base_url = glue("digitalocean").base_url
    local s = {
      inference_base_url = "https://inference.do-ai.run",
      actions_base_url = "https://actions.do-ai.run",
    }
    t.eq(base_url(s, { uri = "/v2/droplets" }), "https://api.digitalocean.com")
    t.eq(base_url(s, { uri = "/x", server = "inference" }), "https://inference.do-ai.run")
    local url, err = base_url(s, { uri = "/x", server = "gpu" })
    t.eq(url, nil)
    t.eq(err.tag, "SdkError")
  end)

  t.it("rivet: the token from RIVET_ENDPOINT's userinfo, removed from the URL", function()
    local c, host =
      client("rivet", { env = { RIVET_ENDPOINT = "https://user:s%3Dcret@api.rivet.test/" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://api.rivet.test/things/x")
    t.eq(host.requests[1].headers.authorization, "Bearer s=cret")
    local c2, host2 = client("rivet", { env = {} })
    local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
    t.match(err.message, "RIVET_TOKEN is required", true)
    t.eq(#host2.requests, 0)
  end)

  t.it("proxmox: the endpoint rule, PVEAPIToken, booleans as 1/0, { data } unwrapped", function()
    local env = {
      PROXMOX_ENDPOINT = "https://pve.test:8006",
      PROXMOX_TOKEN_ID = "root@pam!ci",
      PROXMOX_TOKEN_SECRET = "uuid",
    }
    local c, host =
      client("proxmox", { env = env, responses = { json_response({ data = THING }) } })
    local out = must(c:get_thing({ thing_id = "x", verbose = true }))
    t.eq(out.thing.id, "t1")
    t.eq(host.requests[1].url, "https://pve.test:8006/api2/json/things/x?v=1")
    t.eq(host.requests[1].headers.authorization, "PVEAPIToken=root@pam!ci=uuid")
    for _, bad in ipairs({
      "http://pve.test",
      "https://u:p@pve.test",
      "https://pve.test/api",
      "https://pve.test?x=1",
    }) do
      env.PROXMOX_ENDPOINT = bad
      local c2, host2 = client("proxmox", { env = env })
      t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
      t.eq(#host2.requests, 0, bad)
    end
  end)

  t.it("mailchimp: the data centre from the key; none is a ConfigError without the key", function()
    local c, host = client("mailchimp", { env = { MAILCHIMP_API_KEY = "abc123-US21" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://us21.api.mailchimp.com/3.0/things/x")
    t.match(host.requests[1].headers.authorization, "^Basic ")
    local c2, host2 = client("mailchimp", { env = { MAILCHIMP_API_KEY = "abc123" } })
    local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
    t.no_match(err.message, "abc123", true)
    t.eq(#host2.requests, 0)
    local c3, host3 = client(
      "mailchimp",
      { env = { MAILCHIMP_API_KEY = "abc123", MAILCHIMP_SERVER_PREFIX = "us5" } }
    )
    must(c3:get_thing({ thing_id = "x" }))
    t.eq(host3.requests[1].url, "https://us5.api.mailchimp.com/3.0/things/x")
  end)

  t.it("zendesk: subdomain to origin; an access token beats email + API token", function()
    local c, host = client("zendesk", {
      env = { ZENDESK_SUBDOMAIN = " acme ", ZENDESK_EMAIL = "a@b.c", ZENDESK_API_TOKEN = "zt" },
    })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://acme.zendesk.com/things/x")
    t.eq(host.requests[1].headers.authorization, "Basic YUBiLmMvdG9rZW46enQ=")
    local c2, host2 = client("zendesk", {
      env = {
        ZENDESK_SUBDOMAIN = "https://help.acme.com/",
        ZENDESK_ACCESS_TOKEN = "oa",
        ZENDESK_API_TOKEN = "zt",
      },
    })
    must(c2:get_thing({ thing_id = "x" }))
    t.eq(host2.requests[1].url, "https://help.acme.com/things/x")
    t.eq(host2.requests[1].headers.authorization, "Bearer oa")
    local c3 = client("zendesk", { env = { ZENDESK_API_TOKEN = "zt" } })
    t.fails_with("ConfigError", c3:get_thing({ thing_id = "x" }))
  end)

  t.it("chronosphere, fly_io, onepassword, hydradb settings and transforms", function()
    local chrono = glue("chronosphere").settings
    t.eq(chrono({ base_url = "acme" }).base_url, "https://acme.chronosphere.io")
    t.eq(chrono({ base_url = "acme.example.com/" }).base_url, "https://acme.example.com")
    t.eq(chrono({ base_url = "HTTP://localhost:9/" }).base_url, "HTTP://localhost:9")
    local fly = glue("fly_io").settings
    t.eq(fly({ base_url = " https://api.machines.dev/v1/ " }).base_url, "https://api.machines.dev")
    t.eq(fly({ base_url = "  " }).base_url, nil)
    local op = glue("onepassword").settings
    t.eq(op({ connect_host = "http://op.local:8080/" }).base_url, "http://op.local:8080/v1")
    t.eq(op({ connect_host = "http://op.local/V1" }).base_url, "http://op.local/V1")
    t.eq(op({ base_url = "https://given", connect_host = "x" }).base_url, "https://given")
    local unwrap = glue("hydradb").transform_response
    t.eq(json.encode(unwrap(json.decode('{"success":true,"data":{"a":1},"meta":{}}'))), '{"a":1}')
    local other = json.decode('{"success":true,"data":{},"extra":1}')
    t.eq(unwrap(other), other)
  end)
end)

t.describe("providers: OAuth client credentials through a generated client", function()
  t.it("starburst_galaxy: a bare domain is https; the token is reused for half its life", function()
    local c, host = client("starburst_galaxy", {
      env = {
        STARBURST_GALAXY_DOMAIN = "yourco.galaxy.starburst.io",
        STARBURST_GALAXY_CLIENT_ID = "cid",
        STARBURST_GALAXY_CLIENT_SECRET = "csec",
      },
      responses = {
        json_response({ access_token = "at", expires_in = 100 }),
        json_response(THING),
        json_response(THING),
        json_response({ access_token = "at2", expires_in = 100 }),
        json_response(THING),
      },
    })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].url, "https://yourco.galaxy.starburst.io/oauth/v2/token")
    t.eq(host.requests[1].headers.authorization, "Basic Y2lkOmNzZWM=")
    t.eq(host.requests[2].url, "https://yourco.galaxy.starburst.io/things/x")
    t.eq(host.requests[2].headers.authorization, "Bearer at")
    host.advance(49)
    must(c:get_thing({ thing_id = "x" }))
    t.eq(#host.requests, 3)
    host.advance(2) -- 100 s token: max(100 - 60, 50) = 50 s
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[4].url, "https://yourco.galaxy.starburst.io/oauth/v2/token")
    t.eq(host.requests[5].headers.authorization, "Bearer at2")
  end)

  t.it("starburst_galaxy: a domain with a path is refused before any request", function()
    local c, host = client("starburst_galaxy", {
      env = {
        STARBURST_GALAXY_DOMAIN = "https://yourco.galaxy.starburst.io/x",
        STARBURST_GALAXY_CLIENT_ID = "cid",
        STARBURST_GALAXY_CLIENT_SECRET = "csec",
      },
    })
    local err = t.fails_with("ConfigError", c:get_thing({ thing_id = "x" }))
    t.match(err.message, "Starburst Galaxy domain", true)
    t.eq(#host.requests, 0)
  end)

  t.it(
    "tailscale: form credentials at <base>/oauth/token; key and client both set is an error",
    function()
      local c, host = client("tailscale", {
        env = { TAILSCALE_OAUTH_CLIENT_ID = "cid", TAILSCALE_OAUTH_CLIENT_SECRET = "csec" },
        options = { scope = "devices:core" },
        responses = {
          json_response({ access_token = "at", expires_in = 3600 }),
          json_response(THING),
        },
      })
      must(c:get_thing({ thing_id = "x" }))
      t.eq(host.requests[1].url, "https://api.tailscale.com/api/v2/oauth/token")
      t.eq(
        host.requests[1].body,
        "client_id=cid&client_secret=csec&grant_type=client_credentials&scope=devices%3Acore"
      )
      t.eq(host.requests[2].url, "https://api.tailscale.com/api/v2/things/x")
      t.eq(host.requests[2].headers.authorization, "Bearer at")
      local c2, host2 = client("tailscale", {
        env = { TAILSCALE_API_KEY = "k", TAILSCALE_OAUTH_CLIENT_ID = "cid" },
      })
      local err = t.fails_with("ConfigError", c2:get_thing({ thing_id = "x" }))
      t.match(err.message, "not both", true)
      t.eq(#host2.requests, 0)
      local c3, host3 = client(
        "tailscale",
        { env = { TAILSCALE_BASE_URL = "https://ts.example.com/", TAILSCALE_API_KEY = "k" } }
      )
      must(c3:get_thing({ thing_id = "x" }))
      t.eq(host3.requests[1].url, "https://ts.example.com/api/v2/things/x")
    end
  )

  t.it("mongodb_atlas: a refused exchange names the OAuth error and never the secret", function()
    local c, host = client("mongodb_atlas", {
      env = { MONGODB_ATLAS_CLIENT_ID = "cid", MONGODB_ATLAS_CLIENT_SECRET = "s3cr3t" },
      responses = { json_response({ error = "invalid_client" }, 401) },
    })
    local err = t.fails_with("ConfigError", c:get_thing({ thing_id = "x" }))
    t.eq(err.message, "OAuth2 token exchange failed with 401 invalid_client")
    t.no_match(t.show(err), "s3cr3t", true)
    t.eq(host.requests[1].url, "https://cloud.mongodb.com/api/oauth/token")
  end)
end)

t.describe("providers: Stripe's error.type reading", function()
  local function fail(body, status)
    local c = client(
      "stripe",
      { env = { STRIPE_API_KEY = "sk_test" }, responses = { json_response(body, status) } }
    )
    local v, err = c:get_thing({ thing_id = "x" })
    t.eq(v, nil)
    return err
  end

  t.it("card_error, invalid_request_error, api_error and idempotency_error have classes", function()
    local card = fail({
      error = {
        type = "card_error",
        code = "card_declined",
        decline_code = "insufficient_funds",
        message = "Declined",
      },
    }, 402)
    t.eq(card.tag, "CardError")
    t.eq(card.decline_code, "insufficient_funds")
    t.eq(card.code, "card_declined")
    t.truthy(errors.has_category(card, "BadRequestError"))
    local inv = fail(
      { error = { type = "invalid_request_error", param = "amount", message = "Missing" } },
      400
    )
    t.eq(inv.tag, "InvalidRequestError")
    t.eq(inv.param, "amount")
    t.eq(inv.status, 400)
    local api = fail({ error = { type = "api_error", message = "Oops" } }, 500)
    t.eq(api.tag, "ApiError")
    t.truthy(api.retryable)
    t.eq(fail({ error = { type = "idempotency_error" } }, 409).tag, "IdempotencyError")
  end)

  t.it(
    "another type: 402 PaymentError, 424 ExternalDependencyFailed, else the shared map",
    function()
      t.eq(fail({ error = { type = "invalid_grant", charge = "ch_1" } }, 402).tag, "PaymentError")
      t.eq(fail({ error = { type = "x" } }, 424).tag, "ExternalDependencyFailed")
      local nf = fail({ error = { type = "x", message = "No such" } }, 404)
      t.eq(nf.tag, "NotFound")
      local unk = fail({ error = { type = "temporary_hold", param = "p", message = "Held" } }, 418)
      t.eq(unk.tag, "UnknownStripeError")
      t.eq(unk.type, "temporary_hold")
      t.eq(unk.param, "p")
    end
  )

  t.it("no error.type: UnknownStripeError below 500, InternalServerError at 500", function()
    local unk = fail({ message = "?" }, 400)
    t.eq(unk.tag, "UnknownStripeError")
    t.eq(unk.status, 400)
    local ise = fail("<html>bad gateway</html>", 502)
    t.eq(ise.tag, "BadGateway")
  end)

  t.it("Stripe-Version and the bracket query style reach the request", function()
    local c, host =
      client("stripe", { env = { STRIPE_API_KEY = "sk_test" }, options = { context = "acct_1" } })
    must(c:get_thing({ thing_id = "x" }))
    t.eq(host.requests[1].headers["stripe-version"], "2026-10-28.endive")
    t.eq(host.requests[1].headers["stripe-context"], "acct_1")
    t.match(class_of("stripe").files["init.lua"], 'query_style = "brackets"', true)
  end)
end)

t.describe("providers: the new keys are validated strictly", function()
  local function bad(overrides, pattern)
    local spec, err = provider.validate(fx.provider(overrides))
    t.eq(spec, nil, pattern)
    t.match(tostring(err), pattern, true)
  end

  t.it("options", function()
    bad({ options = { region = { envv = "X" } } }, "options.region: unknown key envv")
    bad(
      { options = { region = { env = "not a var" } } },
      "options.region.env must be an environment variable name"
    )
    bad(
      { options = { region = { env = {} } } },
      "options.region.env must be an environment variable name"
    )
    bad({ options = { k = { secret = true, default = "x" } } }, "a secret has no default")
    bad(
      { options = { k = { secret = true, choices = { "a" } } } },
      "a secret option cannot have choices"
    )
    bad(
      { options = { k = { choices = { "a", "b" }, default = "c" } } },
      "default c is not one of its choices"
    )
    bad(
      { options = { k = { invalid = "default", choices = { "a" } } } },
      'invalid = "default" needs a default'
    )
    bad({ options = { k = { invalid = "error" } } }, "invalid needs choices")
    bad({ options = { retry = {} } }, "retry is a common client option")
    bad({ options = { api_key = {} } }, "auth.from api_key is also declared in options")
    bad({ options = { ["bad-name"] = {} } }, "option names must be Lua identifiers")
  end)

  t.it("auth", function()
    bad(
      { auth = { kind = "basic", username = "u", password = "p" } },
      "auth.username: u is not declared in options"
    )
    bad({
      auth = { kind = "basic", username = "u", password = "p" },
      options = { u = {}, p = {} },
    }, "option p must be secret")
    bad(
      { auth = { kind = "bearer", from = "api_key", prefix = "Token " } },
      'auth.prefix is for kind = "header"'
    )
    bad(
      { auth = { kind = "bearer", from = "api_key", env = { "A", 3 } } },
      "auth.env must be an environment variable name"
    )
    bad({ auth = { kind = "digest" } }, "auth.kind must be bearer, header, basic or none")
  end)

  t.it("headers and templates", function()
    bad({ headers = { ["X-V"] = "{version}" } }, "headers[x-v]: {version} is not an option")
    bad({ headers = { ["X-V"] = "{oops" } }, "a { or } that is not an {option} reference")
    bad({ headers = { Authorization = "x" } }, "the header is already set")
    bad({ headers = { ["User-Agent"] = "x" } }, "use the user_agent key")
    bad({ headers = { ["bad header"] = "x" } }, "not a header name")
    bad({ headers = { ["X-A"] = { basic = 3 } } }, "basic must be a template")
    bad({ base_url = { default = "https://{site}" } }, "base_url.default: {site} is not an option")
    bad({
      base_url = { default = "https://{base_url}", option = "base_url" },
    }, "cannot use its own option")
    bad(
      { options = { k = { secret = true } }, base_url = { default = "https://{k}" } },
      "{k} is a secret"
    )
    bad(
      { base_url = { default = "https://x.test", ensure_suffix = "api" } },
      "ensure_suffix must be a path"
    )
    bad(
      { base_url = { default = "https://x.test", origin = { lable = "x" } } },
      "base_url.origin: unknown key lable"
    )
  end)

  t.it("oauth, require_one_of, error classes, transforms, glue", function()
    bad({
      oauth = {
        token_url = "{base_url}/t",
        client_id = "id",
        client_secret = "s",
        into = "api_key",
      },
    }, "oauth.client_id must name an option")
    bad({
      options = { id = {}, s = {} },
      oauth = {
        token_url = "{base_url}/t",
        client_id = "id",
        client_secret = "s",
        into = "api_key",
      },
    }, "oauth.client_secret: option s must be secret")
    bad({ require_one_of = { "api_key" } }, "require_one_of must list two or more options")
    bad({ error_classes = { Gone = { categories = { "Nope" } } } }, "unknown category Nope")
    bad({ error_classes = { ["bad tag"] = {} } }, "is not an error tag")
    bad({ unknown_fields = { status = "/x" } }, "status is not a free field name")
    bad({ unknown_fields = { reason = "reason" } }, "unknown_fields.reason must be a JSON pointer")
    bad({ transform_response = { "unwrap" } }, 'must be "strip_nulls" or { unwrap = key')
    bad(
      { error_envelope = { message = { "/a", "b" } } },
      "error_envelope.message must be a JSON pointer"
    )
    bad({ glue = "glue/none.lua" }, "cannot read glue/none.lua")
    bad({ query_style = "commas" }, 'query_style must be "dotted" or "brackets"')
    bad({ user_agent = { default = "" } }, "user_agent.default must be a string")
  end)

  t.it("a glue function that is not a hook, and the generator's model checks", function()
    local spec, err = provider.load(t.root .. "/providers/stackit.lua")
    t.truthy(spec, err)
    local files, gerr = fx.generate({
      provider = fx.provider({
        error_classes = { NotFound = {} },
      }),
    })
    t.eq(files, nil)
    t.match(gerr, "error_classes.NotFound has the tag of", true)
    -- a model error of the same tag is the class (Vercel's PaymentRequired in some models)
    local files3 = must(fx.generate({
      provider = fx.provider({
        error_classes = { Throttled = {}, Gone = { categories = { "NotFoundError" } } },
        status_map = { [429] = "Throttled", [410] = "Gone" },
      }),
    }))
    t.no_match(files3["init.lua"], "provider_errors.Throttled", true)
    t.match(files3["init.lua"], "status_map[429] = service.errors.Throttled", true)
    t.match(files3["init.lua"], "status_map[410] = provider_errors.Gone", true)
    local files2, gerr2 =
      fx.generate({ provider = fx.provider({ public_operations = { "Nope" } }) })
    t.eq(files2, nil)
    t.match(gerr2, "public_operations names an unknown operation Nope", true)
  end)
end)

t.describe("providers: Technitium's 2xx envelope", function()
  local ENV = { TECHNITIUM_API_TOKEN = "tt", TECHNITIUM_API_URL = "http://localhost:5380/" }

  t.it("status ok yields response, or the body without the envelope members", function()
    local c, host = client("technitium", {
      env = ENV,
      responses = {
        json_response({ status = "ok", response = THING }),
        json_response({ status = "ok", server = "dns1", thing = { id = "t2" } }),
      },
    })
    t.eq(must(c:get_thing({ thing_id = "x" })).thing.id, "t1")
    t.eq(host.requests[1].url, "http://localhost:5380/things/x")
    t.eq(host.requests[1].headers.authorization, "Bearer tt")
    t.eq(must(c:get_thing({ thing_id = "x" })).thing.id, "t2")
  end)

  t.it("error, invalid-token, 2fa-required, other statuses and non-objects", function()
    local c = client("technitium", {
      env = ENV,
      responses = {
        json_response({ status = "error", errorMessage = "Zone exists", innerErrorMessage = "dup" }),
        json_response({ status = "error", errorMessage = "Access was denied." }),
        json_response({ status = "invalid-token", errorMessage = "Invalid token" }),
        json_response({ status = "2fa-required", errorMessage = "Need OTP" }),
        json_response({ status = "weird" }),
        json_response({ 1, 2 }),
        json_response({ errorMessage = "Not here" }, 404),
      },
    })
    local e1 = t.fails_with("TechnitiumError", c:get_thing({ thing_id = "x" }))
    t.eq(e1.message, "Zone exists")
    t.eq(e1.innerMessage, "dup")
    t.truthy(errors.has_category(e1, "BadRequestError"))
    t.fails_with("Forbidden", c:get_thing({ thing_id = "x" }))
    t.fails_with("Unauthorized", c:get_thing({ thing_id = "x" }))
    t.truthy(
      errors.has_category(
        t.fails_with("TwoFactorAuthRequired", c:get_thing({ thing_id = "x" })),
        "AuthError"
      )
    )
    t.eq(
      t.fails_with("UnknownTechnitiumError", c:get_thing({ thing_id = "x" })).message,
      'Unknown status "weird"'
    )
    t.eq(
      t.fails_with("UnknownTechnitiumError", c:get_thing({ thing_id = "x" })).message,
      "Response is not a JSON object"
    )
    t.eq(t.fails_with("NotFound", c:get_thing({ thing_id = "x" })).message, "Not here")
  end)

  t.it("the server URL must be an origin, https unless loopback", function()
    local c, host = client("technitium", {
      env = { TECHNITIUM_API_TOKEN = "tt", TECHNITIUM_API_URL = "http://dns.example.com" },
    })
    local err = t.fails_with("ConfigError", c:get_thing({ thing_id = "x" }))
    t.match(err.message, "Technitium API URL must use HTTPS", true)
    t.eq(#host.requests, 0)
  end)
end)

t.describe("providers: per-model base URL overrides (task 10) reach the runtime data", function()
  t.it("models.override.<m>.base_url replaces the default and declares a new option", function()
    local spec = must(provider.validate({
      name = "entire",
      title = "Entire",
      base_url = {
        default = "https://aws-us-east-2.api.entire.io",
        option = "base_url",
        env = "ENTIRE_API_BASE_URL",
      },
      auth = { kind = "bearer", from = "token", env = { "ENTIRE_TOKEN" } },
      unknown_tag = "UnknownEntireError",
      parse_tag = "EntireParseError",
      models = {
        override = {
          orgs = {
            base_url = {
              option = "core_base_url",
              env = "ENTIRE_CORE_BASE_URL",
              default = "https://us.console.entire.io",
            },
          },
        },
      },
    }))
    local cell = provider.for_model(spec, "repos")
    t.eq(cell.runtime.base_url.default, "https://aws-us-east-2.api.entire.io")
    local core = provider.for_model(spec, "orgs")
    t.eq(core.runtime.base_url.default, "https://us.console.entire.io")
    t.eq(core.runtime.base_url.option, "core_base_url")
    t.same(core.runtime.options.core_base_url, { env = { "ENTIRE_CORE_BASE_URL" } })
    t.same(core.client_options.core_base_url, { type = "string" })
    t.eq(spec.runtime.options.core_base_url, nil) -- the package spec is unchanged
  end)
end)
