-- Per-model auth, options and headers (task 27): provider spec models.override and the
-- committed clients of the packages whose models have their own credentials (clerk,
-- convex, digitalocean, exa, onepassword, mailchimp, fly_io, e2b). Each client case
-- names the Distilled protocol/credentials code it follows.
local t = require("spec.harness")
local crypto = require("distilled.crypto")
local json = require("distilled.json")
local provider = require("distilled.gen.provider")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function base_spec(extra)
  local s = {
    name = "ex",
    title = "Ex",
    base_url = { default = "https://api.ex.test/v1", option = "base_url", env = "EX_BASE_URL" },
    auth = { kind = "bearer", from = "api_key", env = "EX_API_KEY" },
    options = { api_version = { default = "1" } },
    headers = { ["Ex-Version"] = "{api_version}" },
    unknown_tag = "UnknownExError",
    parse_tag = "ExParseError",
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function client(class, opts, responses)
  local host = testing.host({ responses = responses or {}, env = opts.env or {} })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  return class.new(o), host
end

local function b64(s)
  return crypto.base64.encode(s)
end

t.describe("provider spec models.override: auth, options, headers (task 27)", function()
  t.it("gives a model its own validated spec; false removes a package key", function()
    local spec, err = provider.validate(base_spec({
      models = {
        override = {
          other = {
            base_url = {
              default = "https://other.ex.test",
              env = "EX_OTHER_URL",
              ensure_suffix = "/v2",
            },
            auth = { kind = "header", header = "x-key", from = "other_key", env = "EX_OTHER_KEY" },
            options = false,
            headers = false,
          },
        },
      },
    }))
    t.eq(err, nil)
    local m = provider.for_model(spec, "other")
    t.eq(m.name, "ex.other")
    t.eq(m.title, "ExOther")
    t.eq(m.package, "ex")
    t.eq(m.runtime.base_url.default, "https://other.ex.test")
    t.eq(m.runtime.base_url.ensure_suffix, "/v2")
    t.same(m.runtime.options.base_url.env, { "EX_OTHER_URL" })
    t.same(m.runtime.options.other_key.env, { "EX_OTHER_KEY" })
    t.eq(m.runtime.options.api_key, nil, "the package's auth option is gone")
    t.eq(m.runtime.options.api_version, nil, "options = false")
    t.eq(#m.runtime.headers, 1)
    t.eq(m.runtime.headers[1].name, "x-key")
    -- the package itself and other models are unchanged
    local plain = provider.for_model(spec, "plain")
    t.same(plain.runtime.options.api_key.env, { "EX_API_KEY" })
    t.eq(#plain.runtime.headers, 2)
  end)

  t.it("merges base_url field by field; a false field is removed", function()
    local spec = assert(provider.validate(base_spec({
      models = { override = { m = { base_url = { env = false }, auth = false } } },
    })))
    local m = provider.for_model(spec, "m")
    t.eq(m.runtime.base_url.default, "https://api.ex.test/v1")
    t.eq(m.runtime.options.base_url.env, nil)
    t.eq(m.auth.kind, "none")
  end)

  t.it("reports a problem in a model's spec under the model's name", function()
    local _, err = provider.validate(base_spec({
      models = { override = { m = { auth = { kind = "basic", username = "u", password = "p" } } } },
    }))
    t.match(
      err,
      "models.override.m: provider spec auth.username: u is not declared in options",
      true
    )
  end)

  t.it("refuses keys a model cannot override, listing the allowed ones", function()
    local _, err = provider.validate(base_spec({
      models = { override = { m = { unknown_tag = "X" } } },
    }))
    t.match(err, "models.override.m: unknown key unknown_tag (allowed: auth, base_url,", true)
  end)

  t.it("keeps a title/base_url-only override on the classic path", function()
    local spec = assert(provider.validate(base_spec({
      models = { override = { m = { title = "Emm", base_url = "https://m.ex.test" } } },
    })))
    t.eq(spec.models.override.m.spec, nil)
    local m = provider.for_model(spec, "m")
    t.eq(m.title, "Emm")
    t.eq(m.runtime.base_url.default, "https://m.ex.test")
  end)
end)

t.describe("provider spec pagination.modes (task 27)", function()
  t.it("maps a trait mode to a runtime strategy; refuses unknown modes", function()
    local spec =
      assert(provider.validate(base_spec({ pagination = { modes = { page = "total_count" } } })))
    t.same(spec.pagination.modes, { page = "total_count" })
    local _, err = provider.validate(base_spec({ pagination = { modes = { page = "pages" } } }))
    t.match(err, "pagination.modes.page: pages is not a distilled.paginate mode", true)
    _, err = provider.validate(base_spec({ pagination = { modes = { offset = "page" } } }))
    t.match(err, "pagination.modes: offset is not a trait mode", true)
  end)
end)

t.describe("clerk.platform (ClerkPlatformProtocol)", function()
  local Platform = require("clerk.platform")
  t.it("bearer CLERK_PLATFORM_API_KEY, no Clerk-API-Version, /v1 appended once", function()
    local c, host = client(Platform, { env = { CLERK_PLATFORM_API_KEY = "plat_FAKE" } }, {
      { status = 200, body = { id = "app_1" } },
      { status = 200, body = { id = "app_1" } },
    })
    local _, err = c:get_application({ applicationID = "app_1" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.url, "https://api.clerk.com/v1/platform/applications/app_1")
    t.eq(req.headers.authorization, "Bearer plat_FAKE")
    t.eq(req.headers["clerk-api-version"], nil)
    c = Platform.new({ host = host, retry = "none", base_url = "https://proxy.test/v1/" })
    c:get_application({ applicationID = "app_1" })
    t.eq(host.requests[2].url, "https://proxy.test/v1/platform/applications/app_1")
  end)

  t.it("the backend model keeps CLERK_SECRET_KEY and the version header", function()
    local Clerk = require("clerk.clerk")
    local c, host = client(Clerk, { env = { CLERK_SECRET_KEY = "sk_FAKE" } }, {
      { status = 200, body = {} },
    })
    c:get_user({ user_id = "u1" })
    t.eq(host.requests[1].headers["clerk-api-version"], "2026-05-12")
    t.eq(host.requests[1].headers.authorization, "Bearer sk_FAKE")
  end)

  t.it("a missing platform key is a ConfigError naming the variable", function()
    local c = client(Platform, {})
    t.fails_with("ConfigError", c:get_application({ applicationID = "a" }))
    local _, err = c:get_application({ applicationID = "a" })
    t.match(err.message, "CLERK_PLATFORM_API_KEY", true)
  end)
end)

t.describe("convex.deployment and convex.functions", function()
  t.it("deployment: Authorization Convex <token>, <deploymentUrl>/api/v1", function()
    local D = require("convex.deployment")
    local c, host = client(D, {
      deployment_url = "https://happy-cat-1.convex.cloud/",
      env = { CONVEX_ACCESS_TOKEN = "dk_FAKE" },
    }, { { status = 200, body = {} } })
    local _, err = c:delete_integration({ id = "i1" })
    t.eq(err, nil)
    t.eq(host.requests[1].url, "https://happy-cat-1.convex.cloud/api/v1/integrations/i1")
    t.eq(host.requests[1].headers.authorization, "Convex dk_FAKE")
  end)

  t.it("deployment without deployment_url is a ConfigError (no request)", function()
    local D = require("convex.deployment")
    local c, host = client(D, { access_token = "dk_FAKE" })
    local _, err = c:delete_integration({ id = "i1" })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "deployment_url")
    t.eq(#host.requests, 0)
    t.no_match(err.message, "dk_FAKE", true)
  end)

  t.it("functions: no auth header, <deploymentUrl>/api", function()
    local F = require("convex.functions")
    local c, host = client(F, {
      deployment_url = "https://happy-cat-1.convex.cloud",
      env = { CONVEX_ACCESS_TOKEN = "dk_FAKE" },
    }, { { status = 200, body = { status = "success", value = 1 } } })
    local _, err = c:query({ path = "messages:list", args = {} })
    t.eq(err, nil)
    t.eq(host.requests[1].url, "https://happy-cat-1.convex.cloud/api/query")
    t.eq(host.requests[1].headers.authorization, nil)
  end)
end)

t.describe("digitalocean.functions (FunctionsProtocol)", function()
  local F = require("digitalocean.functions")
  t.it("Basic user:secret to api_host; failures read { error }", function()
    local c, host = client(F, {
      api_host = "https://faas-nyc1-2ef2e6cc.doserverless.co",
      user = "ns-uuid",
      secret = "ns-key-FAKE",
    }, {
      { status = 200, body = { name = "hello" } },
      { status = 404, body = { error = "The requested resource does not exist.", code = "req-1" } },
    })
    local _, err = c:get_action_by_name({ namespace = "_", actionName = "hello" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.url, "https://faas-nyc1-2ef2e6cc.doserverless.co/api/v1/namespaces/_/actions/hello")
    t.eq(req.headers.authorization, "Basic " .. b64("ns-uuid:ns-key-FAKE"))
    _, err = c:get_action_by_name({ namespace = "_", actionName = "nope" })
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "The requested resource does not exist.")
    t.eq(err.code, nil, "code is a request id, not an error code")
  end)

  t.it("api_host is required (no default, no environment variable)", function()
    local c =
      client(F, { user = "u", secret = "s", env = { DIGITALOCEAN_API_BASE_URL = "https://x" } })
    local _, err = c:get_action_by_name({ namespace = "_", actionName = "a" })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "api_host")
  end)
end)

t.describe("exa.team_management (ExaTeamManagementProtocol)", function()
  local TM = require("exa.team_management")
  t.it("x-api-key is the service key when set, else the API key", function()
    local c, host = client(TM, {
      env = { EXA_API_KEY = "exa_FAKE", EXA_SERVICE_API_KEY = "svc_FAKE" },
    }, { { status = 200, body = {} }, { status = 200, body = {} } })
    c:get_api_key({ id = "k1" })
    t.eq(host.requests[1].url, "https://admin-api.exa.ai/team-management/api-keys/k1")
    t.eq(host.requests[1].headers["x-api-key"], "svc_FAKE")
    host.env.EXA_SERVICE_API_KEY = nil
    c = TM.new({ host = host, retry = "none", api_key = "exa_ONLY" })
    local _, err = c:get_api_key({ id = "k1" })
    t.eq(err, nil)
    t.eq(host.requests[2].headers["x-api-key"], "exa_ONLY")
  end)

  t.it("neither key is a ConfigError", function()
    local c = client(TM, {})
    t.fails_with("ConfigError", c:get_api_key({ id = "k1" }))
  end)
end)

t.describe("onepassword models (EventsProtocol, UsersProtocol, OAuthProtocol, ...)", function()
  t.it("users: exchanges the client credentials once, then sends the bearer token", function()
    local Users = require("onepassword.users")
    local c, host = client(Users, {
      env = { OP_USERS_API_CLIENT_ID = "cid", OP_USERS_API_CLIENT_SECRET = "csecret_FAKE" },
    }, {
      { status = 200, body = { access_token = "at_FAKE", expires_in = 900 } },
      { status = 200, body = {} },
      { status = 200, body = {} },
    })
    t.eq(select(2, c:get_user({ account = "a", user = "u" })), nil)
    c:get_user({ account = "a", user = "u" })
    local tok = host.requests[1]
    t.eq(tok.method, "POST")
    t.eq(tok.url, "https://api.1password.com/v1/oauth/token")
    t.eq(tok.headers.authorization, "Basic " .. b64("cid:csecret_FAKE"))
    t.eq(tok.body, "grant_type=client_credentials")
    t.eq(host.requests[2].url, "https://api.1password.com/v1/accounts/a/users/u")
    t.eq(host.requests[2].headers.authorization, "Bearer at_FAKE")
    t.eq(host.requests[3].headers.authorization, "Bearer at_FAKE")
    t.eq(#host.requests, 3, "the token is reused")
  end)

  t.it("users: a refused exchange is a ConfigError without the secret", function()
    local Users = require("onepassword.users")
    -- another client id: the token cache lives with the protocol (one per client module)
    local c, host = client(Users, { client_id = "cid2", client_secret = "csecret_FAKE" }, {
      { status = 401, body = { error = "invalid_client" } },
    })
    local _, err = c:get_user({ account = "a", user = "u" })
    t.eq(err.tag, "ConfigError")
    t.no_match(err.message, "csecret_FAKE", true)
    t.eq(#host.requests, 1)
  end)

  t.it("events: OP_EVENTS_API_TOKEN, its own host, failures { Error = { Message } }", function()
    local Events = require("onepassword.events")
    local c, host = client(Events, { env = { OP_EVENTS_API_TOKEN = "ev_FAKE" } }, {
      { status = 401, body = { Error = { Message = "Unauthorized token" } } },
    })
    local _, err = c:get_auth_introspect_v2({})
    t.eq(host.requests[1].url, "https://events.1password.com/api/v2/auth/introspect")
    t.eq(host.requests[1].headers.authorization, "Bearer ev_FAKE")
    t.eq(err.tag, "Unauthorized")
    t.eq(err.message, "Unauthorized token")
  end)

  t.it("oauth: Basic client credentials; failures { error, error_description }", function()
    local OAuth = require("onepassword.oauth")
    local c, host = client(OAuth, { client_id = "cid", client_secret = "cs_FAKE" }, {
      { status = 400, body = { error = "invalid_grant", error_description = "bad grant" } },
    })
    local _, err = c:revoke_access_token({ token = "x" })
    t.eq(host.requests[1].headers.authorization, "Basic " .. b64("cid:cs_FAKE"))
    t.eq(err.message, "bad grant")
    t.eq(err.code, "invalid_grant")
  end)

  t.it("partnership: OP_PARTNERSHIP_API_TOKEN; failures { error, description }", function()
    local P = require("onepassword.partnership")
    local c, host = client(P, {
      env = {
        OP_PARTNERSHIP_API_TOKEN = "pt_FAKE",
        OP_PARTNERSHIP_API_BASE_URL = "https://b.test/",
      },
    }, { { status = 404, body = { error = "not_found", description = "no account" } } })
    local _, err = c:get_account({ customer_account_uid = "c1" })
    t.eq(host.requests[1].url, "https://b.test/api/v1/partners/accounts/c1")
    t.eq(err.message, "no account")
  end)
end)

t.describe("mailchimp.transactional (MailchimpTransactionalProtocol)", function()
  local T = require("mailchimp.transactional")
  t.it("sends the key as the `key` body member, from MANDRILL_API_KEY too", function()
    local c, host = client(T, { env = { MANDRILL_API_KEY = "md_FAKE" } }, {
      { status = 200, body = { email = "a@b.test", added = true } },
    })
    local _, err = c:add_allowlist_entry({ email = "a@b.test" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.url, "https://mandrillapp.com/api/1.0/allowlists/add")
    t.eq(req.headers.authorization, nil)
    local body = json.decode(req.body)
    t.eq(body.key, "md_FAKE")
    t.eq(body.email, "a@b.test")
  end)

  t.it("reads { status = error, name, message }; MailchimpTransactionalError keeps name", function()
    local c = client(T, { api_key = "md_FAKE" }, {
      {
        status = 418,
        body = { status = "error", code = -1, name = "Invalid_Key", message = "Invalid API key" },
      },
    })
    local _, err = c:add_allowlist_entry({ email = "a@b.test" })
    t.eq(err.tag, "MailchimpTransactionalError")
    t.eq(err.message, "Invalid_Key: Invalid API key")
    t.eq(err.name, "Invalid_Key")
    t.eq(err.code, -1)
    t.eq(err.status, 418)
  end)

  t.it("a mapped status keeps the core class with the Mandrill message", function()
    local c = client(T, { api_key = "md_FAKE" }, {
      {
        status = 401,
        body = { status = "error", code = -1, name = "Invalid_Key", message = "Invalid API key" },
      },
    })
    local _, err = c:add_allowlist_entry({ email = "a@b.test" })
    t.eq(err.tag, "Unauthorized")
    t.eq(err.message, "Invalid_Key: Invalid API key")
  end)

  t.it("marketing: a problem document on an unmapped status is MailchimpApiError", function()
    local M = require("mailchimp.marketing")
    local c = client(M, { api_key = "k-us21" }, {
      {
        status = 405,
        body = {
          type = "about:blank",
          title = "Method Not Allowed",
          detail = "no",
          instance = "i-1",
        },
      },
      { status = 418, body = "teapot" },
    })
    local _, err =
      c:add_list_member({ list_id = "l1", email_address = "a@b.test", status = "subscribed" })
    t.eq(err.tag, "MailchimpApiError")
    t.eq(err.message, "no")
    t.eq(err.title, "Method Not Allowed")
    t.eq(err.instance, "i-1")
    _, err =
      c:add_list_member({ list_id = "l1", email_address = "a@b.test", status = "subscribed" })
    t.eq(err.tag, "UnknownMailchimpError")
  end)
end)

t.describe("fly_io.mpg and fly_io.sprites (FlyApiProtocol, SpritesProtocol)", function()
  t.it("mpg: the fixed https://api.fly.io host, the Fly token", function()
    local Mpg = require("fly_io.mpg")
    local c, host = client(
      Mpg,
      { env = { FLY_API_TOKEN = "fo1_FAKE", FLY_API_HOSTNAME = "https://m.test" } },
      {
        { status = 200, body = {} },
      }
    )
    c:get_cluster_by_id({ id = "c1" })
    t.eq(host.requests[1].url, "https://api.fly.io/api/v1/postgresv2/c1")
    t.eq(host.requests[1].headers.authorization, "Bearer fo1_FAKE")
  end)

  t.it("sprites: mints a token once (org from /v1/tokens/current), then sends it", function()
    local Sprites = require("fly_io.sprites")
    local fly = "FlyV1 fm2_FAKE-ONE"
    local c, host = client(Sprites, { api_key = fly }, {
      { status = 200, body = { tokens = { { org_slug = "personal" } } } },
      { status = 200, body = { token = "spr_MINTED" } },
      { status = 200, body = {} },
      { status = 200, body = {} },
    })
    local _, err = c:list_exec_sessions({ name = "box" })
    t.eq(err, nil)
    c:list_exec_sessions({ name = "box" })
    local r = host.requests
    t.eq(r[1].url, "https://api.machines.dev/v1/tokens/current")
    t.eq(r[1].headers.authorization, "Bearer " .. fly)
    t.eq(r[2].url, "https://api.sprites.dev/v1/organizations/personal/tokens")
    t.eq(r[2].headers.authorization, "FlyV1 fm2_FAKE-ONE")
    t.eq(r[3].url, "https://api.sprites.dev/v1/sprites/box/exec")
    t.eq(r[3].headers.authorization, "Bearer spr_MINTED")
    t.eq(r[4].headers.authorization, "Bearer spr_MINTED")
    t.eq(#r, 4, "minted once")
  end)

  t.it("sprites: GraphQL discovery; the mint op itself uses FlyV1", function()
    local Sprites = require("fly_io.sprites")
    local c, host = client(Sprites, { api_key = "fm2_FAKE-TWO" }, {
      { status = 401, body = { error = "nope" } },
      { status = 200, body = { data = { viewer = { personalOrganization = { slug = "me" } } } } },
      { status = 200, body = { token = "spr_2" } },
      { status = 200, body = {} },
      { status = 200, body = { token = "x" } },
    })
    c:list_exec_sessions({ name = "box" })
    t.eq(host.requests[2].url, "https://api.fly.io/graphql")
    t.eq(host.requests[3].url, "https://api.sprites.dev/v1/organizations/me/tokens")
    t.eq(host.requests[4].headers.authorization, "Bearer spr_2")
    c:create_organization_token({ org = "me" })
    t.eq(host.requests[5].headers.authorization, "FlyV1 fm2_FAKE-TWO")
    t.eq(#host.requests, 5, "the mint operation needs no minted token")
  end)

  t.it("sprites: a 401 'sprites not enabled' at the mint is SpritesNotEnabled", function()
    local Sprites = require("fly_io.sprites")
    local c = client(Sprites, { api_key = "fm2_FAKE-THREE" }, {
      { status = 200, body = { tokens = { { organization = "o" } } } },
      { status = 401, body = { error = "unauthorized", message = "Sprites not enabled for org" } },
    })
    local _, err = c:list_exec_sessions({ name = "box" })
    t.eq(err.tag, "SpritesNotEnabled")
    t.truthy(err.categories.AuthError)
    t.no_match(err.message, "FAKE-THREE", true)
  end)

  t.it("sprites: exec frames and NDJSON answers", function()
    local Sprites = require("fly_io.sprites")
    local c = client(Sprites, { api_key = "fm2_FAKE-FOUR" }, {
      { status = 200, body = { tokens = { { org_slug = "o" } } } },
      { status = 200, body = { token = "spr_4" } },
      { status = 200, body = "\1hello\3\7" },
      { status = 200, body = '{"a":1}\n{"a":2}\n' },
    })
    local res, err = c:exec_command({ name = "box", cmd = { "echo" } })
    t.eq(err, nil)
    t.eq(res.stdout, "hello")
    t.eq(res.exit_code, 7)
    res = c:list_exec_sessions({ name = "box" })
    t.eq(type(res), "table")
  end)
end)

t.describe("e2b envd and volume_content (EnvdProtocol, VolumeContentProtocol)", function()
  t.it("envd: sandbox headers, the shared host on e2b.app, {} for an empty POST", function()
    local Envd = require("e2b.envd")
    local c, host = client(Envd, { sandbox_id = "sb1", access_token = "envd_FAKE" }, {
      { status = 200, body = {} },
    })
    local _, err = c:freeze_envd({})
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.url, "https://sandbox.e2b.app/freeze")
    t.eq(req.headers["e2b-sandbox-id"], "sb1")
    t.eq(req.headers["e2b-sandbox-port"], "49983")
    t.eq(req.headers["connect-protocol-version"], "1")
    t.eq(req.headers["x-access-token"], "envd_FAKE")
    t.eq(req.body, "{}")
  end)

  t.it("envd: another domain is <port>-<sandbox>.<domain>; sandbox_id is required", function()
    local FS = require("e2b.filesystem")
    local c, host = client(FS, { sandbox_id = "sb2", domain = "e2b.example", port = "5000" }, {
      { status = 200, body = {} },
    })
    c:list_dir({ path = "/" })
    t.eq(host.requests[1].url, "https://5000-sb2.e2b.example/filesystem.Filesystem/ListDir")
    t.eq(host.requests[1].headers["x-access-token"], nil)
    local c2 = client(FS, { env = { E2B_API_KEY = "k" } })
    local _, err = c2:list_dir({ path = "/" })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "sandbox_id")
  end)

  t.it("volume_content: bearer volume token to https://api.<domain>", function()
    local V = require("e2b.volume_content")
    local c, host = client(V, { token = "vol_FAKE", env = { E2B_API_KEY = "team_FAKE" } }, {
      { status = 200, body = {} },
    })
    c:list_volume_dir({ volumeID = "v1", path = "/" })
    t.match(host.requests[1].url, "^https://api%.e2b%.app/volumecontent/v1/dir")
    t.eq(host.requests[1].headers.authorization, "Bearer vol_FAKE")
    t.eq(host.requests[1].headers["x-api-key"], nil)
  end)
end)
