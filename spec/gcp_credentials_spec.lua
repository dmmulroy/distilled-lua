-- GCP credentials providers (distilled.gcp.credentials), through a generated client and
-- fake Google endpoints. Ported from Distilled's packages/gcp/test/credential-providers/
-- (from-application-default.test.ts, from-workload-identity.test.ts); the file system is
-- the `read_file` seam, the environment `host.getenv`, the clock `host.epoch`.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local creds = require("distilled.gcp.credentials")
local jwt = require("distilled.crypto.jwt")
local pem = require("distilled.crypto.pem")
local b64 = require("distilled.crypto.base64")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path
local ResourceManager = require("gcp.cloudresourcemanager_v3")

local function read(path)
  local f = assert(io.open(t.root .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end
local KEYS = json.decode(read("spec/golden/crypto_pk/keys.json"))

local function unescape(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end
local function form(body)
  local out = {}
  for k, v in string.gmatch(body or "", "([^&=]+)=([^&]*)") do
    out[unescape(k)] = unescape(v)
  end
  return out
end

local function host_of(u)
  return string.match(u, "^https?://([^/]+)")
end
local function path_of(u)
  return string.match(u, "^https?://[^/]+([^?]*)")
end

-- Fake Google endpoints: `handlers[host](call)` answer first, then defaults. `files` is
-- the file system (CLOUDSDK_CONFIG is /cfg, so gcloud's login is FILES.login).
local LOGIN = "/cfg/application_default_credentials.json"
local function google(opts)
  opts = opts or {}
  local handlers = opts.handlers or {}
  local calls, minted = {}, { n = 0 }
  local h
  local defaults = {
    ["oauth2.googleapis.com"] = function()
      minted.n = minted.n + 1
      return { status = 200, body = { access_token = "oauth-" .. minted.n, expires_in = 3599 } }
    end,
    ["sts.googleapis.com"] = function()
      minted.n = minted.n + 1
      return { status = 200, body = { access_token = "federated-" .. minted.n, expires_in = 3600 } }
    end,
    ["iamcredentials.googleapis.com"] = function()
      return {
        status = 200,
        body = {
          accessToken = "impersonated-" .. minted.n,
          expireTime = os.date("!%Y-%m-%dT%H:%M:%SZ", h.epoch() + 3600),
        },
      }
    end,
    ["metadata.google.internal"] = function()
      return { status = 404, body = "not on GCP" }
    end,
    ["cloudresourcemanager.googleapis.com"] = function()
      return { status = 200, body = { name = "projects/1", projectId = "acme" } }
    end,
  }
  local function transport(req)
    local c = {
      method = req.method,
      url = req.url,
      host = host_of(req.url),
      path = path_of(req.url),
      headers = req.headers or {},
      body = req.body or "",
    }
    calls[#calls + 1] = c
    local f = handlers[c.host] or defaults[c.host]
    if not f then
      error("unexpected request " .. tostring(req.url))
    end
    local r = f(c)
    local body = r.body
    if type(body) == "table" then
      body = json.encode(body)
    end
    return { status = r.status, headers = r.headers or {}, body = body or "" }
  end
  local env = { CLOUDSDK_CONFIG = "/cfg" }
  for k, v in pairs(opts.env or {}) do
    env[k] = v
  end
  h = testing.host({ env = env })
  h.transport = transport
  local files = opts.files or {}
  h.read_file = function(path)
    return files[path]
  end
  h.calls = calls
  h.hosts = function()
    local out = {}
    for i, c in ipairs(calls) do
      out[i] = c.host
    end
    return out
  end
  h.api = function()
    local out = {}
    for _, c in ipairs(calls) do
      if c.host == "cloudresourcemanager.googleapis.com" then
        out[#out + 1] = c
      end
    end
    return out
  end
  return h
end

local function login(extra)
  local v = {
    type = "authorized_user",
    client_id = "764086051850.apps.googleusercontent.com",
    client_secret = "client-secret-value",
    refresh_token = "refresh-token-value",
    quota_project_id = "acme-dev",
  }
  for k, x in pairs(extra or {}) do
    v[k] = x
  end
  return json.encode(v)
end

local function call(h, provider)
  local client = ResourceManager.new({ host = h, retry = "none", credentials = provider })
  return client:get_projects({ name = "projects/1" })
end

t.describe("gcp credentials: from_application_default", function()
  t.it("uses the gcloud login: refresh-token grant, bearer token, quota project header", function()
    local h = google({ files = { [LOGIN] = login() } })
    t.truthy(call(h, creds.from_application_default()))
    t.same(h.hosts(), { "oauth2.googleapis.com", "cloudresourcemanager.googleapis.com" })
    t.eq(h.calls[1].path, "/token")
    -- no scope: the token keeps the scopes granted at login
    t.same(form(h.calls[1].body), {
      grant_type = "refresh_token",
      client_id = "764086051850.apps.googleusercontent.com",
      client_secret = "client-secret-value",
      refresh_token = "refresh-token-value",
    })
    t.eq(h.calls[2].headers.authorization, "Bearer oauth-1")
    t.eq(h.calls[2].headers["x-goog-user-project"], "acme-dev")
  end)

  t.it("resolves the project and quota project: options, then env, then the file", function()
    local files = { [LOGIN] = login() }
    local c = assert(creds.from_application_default():resolve(google({ files = files })))
    t.eq(c.project, "acme-dev")
    t.eq(c.quota_project, "acme-dev")
    local env = { GOOGLE_CLOUD_PROJECT = "env-project", GOOGLE_CLOUD_QUOTA_PROJECT = "env-quota" }
    c = assert(creds.from_application_default():resolve(google({ files = files, env = env })))
    t.eq(c.project, "env-project")
    t.eq(c.quota_project, "env-quota")
    c = assert(
      creds
        .from_application_default({ project = "option-project", quota_project = "option-quota" })
        :resolve(google({ files = files, env = env }))
    )
    t.eq(c.project, "option-project")
    t.eq(c.quota_project, "option-quota")
  end)

  t.it("refreshes once for many requests, and again inside the five-minute window", function()
    local h = google({ files = { [LOGIN] = login() } })
    local p = creds.from_application_default()
    for _ = 1, 4 do
      t.truthy(call(h, p))
    end
    local function minted()
      local n = 0
      for _, c in ipairs(h.calls) do
        n = n + (c.host == "oauth2.googleapis.com" and 1 or 0)
      end
      return n
    end
    t.eq(minted(), 1)
    t.eq(#h.api(), 4)
    h.advance(3599 - 301) -- still outside the window
    t.truthy(call(h, p))
    t.eq(minted(), 1)
    h.advance(2) -- 299 s before expiry: refresh, per attempt
    t.truthy(call(h, p))
    t.eq(minted(), 2)
    t.eq(h.api()[6].headers.authorization, "Bearer oauth-2")
  end)

  t.it("a revoked login fails with GCPCredentialsError that names the fix and no secret", function()
    local h = google({
      files = { [LOGIN] = login() },
      handlers = {
        ["oauth2.googleapis.com"] = function()
          return {
            status = 400,
            body = {
              error = "invalid_grant",
              error_description = "Token has been expired or revoked.",
            },
          }
        end,
      },
    })
    local v, err = call(h, creds.from_application_default())
    t.eq(v, nil)
    t.eq(err.tag, "GCPCredentialsError")
    t.eq(err.status, 400)
    t.match(err.message, "Token has been expired or revoked.", true)
    t.match(err.message, "gcloud auth application-default login", true)
    t.no_match(err.message, "refresh-token-value", true)
    t.no_match(err.message, "client-secret-value", true)
    t.eq(#h.api(), 0)
  end)

  t.it("GOOGLE_APPLICATION_CREDENTIALS wins and signs a service account JWT (RS256)", function()
    local h = google({
      env = { GOOGLE_APPLICATION_CREDENTIALS = "/keys/key.json" },
      files = {
        [LOGIN] = login(),
        ["/keys/key.json"] = json.encode({
          type = "service_account",
          project_id = "acme-prod",
          private_key_id = "key-1",
          private_key = KEYS.rsa2048.pkcs8,
          client_email = "deployer@acme-prod.iam.gserviceaccount.com",
          token_uri = "https://oauth2.googleapis.com/token",
        }),
      },
    })
    local p = creds.from_application_default()
    t.truthy(call(h, p))
    local c = assert(p:resolve(h))
    t.eq(c.project, "acme-prod")
    t.eq(c.quota_project, nil)
    local body = form(h.calls[1].body)
    t.eq(body.grant_type, "urn:ietf:params:oauth:grant-type:jwt-bearer")
    local hdr = string.match(body.assertion, "^([^.]+)")
    t.eq(b64.url_decode(hdr), '{"alg":"RS256","typ":"JWT","kid":"key-1"}')
    local public = assert(pem.public_key(KEYS.rsa2048.spki))
    local claims = assert(jwt.verify(body.assertion, public, { now = h.epoch() }))
    t.eq(claims.iss, "deployer@acme-prod.iam.gserviceaccount.com")
    t.eq(claims.aud, "https://oauth2.googleapis.com/token")
    t.eq(claims.scope, "https://www.googleapis.com/auth/cloud-platform")
    t.eq(claims.iat, h.epoch())
    t.eq(claims.exp - claims.iat, 3600)
    t.eq(h.api()[1].headers["x-goog-user-project"], nil)
    t.eq(h.api()[1].headers.authorization, "Bearer oauth-1")
  end)

  t.it(
    "GOOGLE_APPLICATION_CREDENTIALS naming a missing file is an error, not a fallback",
    function()
      local h = google({
        env = { GOOGLE_APPLICATION_CREDENTIALS = "/cfg/missing.json" },
        files = { [LOGIN] = login() },
      })
      local _, err = call(h, creds.from_application_default())
      t.match(err.message, "missing.json, which does not exist", true)
      t.same(h.hosts(), {})
    end
  )

  t.it("an impersonated_service_account file refreshes the user, then impersonates", function()
    local h = google({
      files = {
        [LOGIN] = json.encode({
          type = "impersonated_service_account",
          service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/deployer@acme.iam.gserviceaccount.com:generateAccessToken",
          delegates = json.array({
            "projects/-/serviceAccounts/middle@acme.iam.gserviceaccount.com",
          }),
          source_credentials = {
            type = "authorized_user",
            client_id = "id",
            client_secret = "secret",
            refresh_token = "refresh",
          },
          quota_project_id = "acme-dev",
        }),
      },
    })
    t.truthy(call(h, creds.from_application_default()))
    t.same(h.hosts(), {
      "oauth2.googleapis.com",
      "iamcredentials.googleapis.com",
      "cloudresourcemanager.googleapis.com",
    })
    t.eq(
      h.calls[2].path,
      "/v1/projects/-/serviceAccounts/deployer%40acme.iam.gserviceaccount.com:generateAccessToken"
    )
    t.eq(h.calls[2].headers.authorization, "Bearer oauth-1")
    t.eq(
      h.calls[2].body,
      json.encode({
        scope = json.array({ "https://www.googleapis.com/auth/cloud-platform" }),
        lifetime = "3600s",
        delegates = json.array({ "projects/-/serviceAccounts/middle@acme.iam.gserviceaccount.com" }),
      })
    )
    t.eq(h.calls[3].headers.authorization, "Bearer impersonated-1")
    t.eq(h.calls[3].headers["x-goog-user-project"], "acme-dev")
  end)

  t.it("an external_account file reads its subject token and exchanges it at STS", function()
    local h = google({
      env = { GOOGLE_APPLICATION_CREDENTIALS = "/k/wif.json" },
      files = {
        ["/k/oidc.json"] = '{"id_token":"oidc-from-file"}',
        ["/k/wif.json"] = json.encode({
          type = "external_account",
          audience = "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/p/providers/q",
          subject_token_type = "urn:ietf:params:oauth:token-type:jwt",
          token_url = "https://sts.googleapis.com/v1/token",
          service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/ci@acme.iam.gserviceaccount.com:generateAccessToken",
          service_account_impersonation = { token_lifetime_seconds = 900 },
          credential_source = {
            file = "/k/oidc.json",
            format = { type = "json", subject_token_field_name = "id_token" },
          },
        }),
      },
    })
    t.truthy(call(h, creds.from_application_default()))
    t.same(h.hosts(), {
      "sts.googleapis.com",
      "iamcredentials.googleapis.com",
      "cloudresourcemanager.googleapis.com",
    })
    t.eq(form(h.calls[1].body).subject_token, "oidc-from-file")
    t.eq(json.decode(h.calls[2].body).lifetime, "900s")
    t.eq(h.calls[3].headers.authorization, "Bearer impersonated-1")
  end)

  t.it(
    "an external_account with a URL credential_source fetches the token with its headers",
    function()
      local h = google({
        env = { GOOGLE_APPLICATION_CREDENTIALS = "/k/wif.json" },
        files = {
          ["/k/wif.json"] = json.encode({
            type = "external_account",
            audience = "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/p/providers/q",
            subject_token_type = "urn:ietf:params:oauth:token-type:jwt",
            credential_source = {
              url = "http://localhost:5000/token",
              headers = { Metadata = "True" },
            },
          }),
        },
        handlers = {
          ["localhost:5000"] = function()
            return { status = 200, body = "oidc-from-url\n" }
          end,
        },
      })
      t.truthy(call(h, creds.from_application_default()))
      t.same(
        h.hosts(),
        { "localhost:5000", "sts.googleapis.com", "cloudresourcemanager.googleapis.com" }
      )
      local md
      for k, v in pairs(h.calls[1].headers) do
        if string.lower(k) == "metadata" then
          md = v
        end
      end
      t.eq(md, "True")
      t.eq(form(h.calls[2].body).subject_token, "oidc-from-url")
    end
  )

  t.it("an external_account with an AWS credential_source says it is unsupported", function()
    local h = google({
      env = { GOOGLE_APPLICATION_CREDENTIALS = "/k/aws.json" },
      files = {
        ["/k/aws.json"] = json.encode({
          type = "external_account",
          audience = "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/p/providers/q",
          subject_token_type = "urn:ietf:params:aws:token-type:aws4_request",
          credential_source = { environment_id = "aws1" },
        }),
      },
    })
    local _, err = call(h, creds.from_application_default())
    t.match(err.message, "AWS or executable credential_source", true)
    t.same(h.hosts(), {})
  end)

  t.it("with no file, the metadata server supplies the token and project", function()
    local h = google({
      handlers = {
        ["metadata.google.internal"] = function(c)
          local headers = { ["metadata-flavor"] = "Google" }
          if string.find(c.path, "/token$") then
            return {
              status = 200,
              headers = headers,
              body = { access_token = "metadata-token", expires_in = 3599 },
            }
          elseif string.find(c.path, "/project/project%-id$") then
            return { status = 200, headers = headers, body = "acme-runtime" }
          end
          return { status = 200, headers = headers, body = "" }
        end,
      },
    })
    local p = creds.from_application_default()
    t.truthy(call(h, p))
    local hosts = h.hosts()
    t.same({ hosts[1], hosts[2], hosts[3] }, {
      "metadata.google.internal",
      "metadata.google.internal",
      "metadata.google.internal",
    })
    for _, c in ipairs(h.calls) do
      if c.host == "metadata.google.internal" then
        t.eq(c.headers["metadata-flavor"], "Google")
      end
    end
    t.eq(h.calls[2].path, "/computeMetadata/v1/instance/service-accounts/default/token")
    t.eq(h.api()[1].headers.authorization, "Bearer metadata-token")
    t.eq(assert(p:resolve(h)).project, "acme-runtime")
  end)

  t.it("with no file and no metadata server, the error says how to log in", function()
    local _, err = call(google(), creds.from_application_default())
    t.eq(err.tag, "GCPCredentialsError")
    t.match(err.message, "gcloud auth application-default login", true)
  end)

  t.it(
    "a server at the metadata address without Metadata-Flavor: Google is not Google Cloud",
    function()
      local h = google({
        handlers = {
          ["metadata.google.internal"] = function()
            return { status = 200, body = { access_token = "not-google" } }
          end,
        },
      })
      local _, err = call(h, creds.from_application_default())
      t.match(err.message, "Could not find Application Default Credentials", true)
      t.same(h.hosts(), { "metadata.google.internal" })
    end
  )

  t.it("an unknown file type is an error that names the supported types", function()
    local h = google({ files = { [LOGIN] = '{"type":"external_account_authorized_user"}' } })
    local _, err = call(h, creds.from_application_default())
    t.match(err.message, 'type "external_account_authorized_user"', true)
  end)
end)

t.describe("gcp credentials: from_workload_identity", function()
  local AUD =
    "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/p/providers/q"

  t.it("exchanges the OIDC token at STS and calls the API with the federated token", function()
    local h = google()
    t.truthy(
      call(h, creds.from_workload_identity({ audience = AUD, subject_token = secret("oidc-1") }))
    )
    t.same(h.hosts(), { "sts.googleapis.com", "cloudresourcemanager.googleapis.com" })
    t.same(form(h.calls[1].body), {
      grant_type = "urn:ietf:params:oauth:grant-type:token-exchange",
      audience = AUD,
      scope = "https://www.googleapis.com/auth/cloud-platform",
      requested_token_type = "urn:ietf:params:oauth:token-type:access_token",
      subject_token = "oidc-1",
      subject_token_type = "urn:ietf:params:oauth:token-type:jwt",
    })
    t.eq(h.calls[2].headers.authorization, "Bearer federated-1")
  end)

  t.it("impersonates the service account with the caller's scopes and lifetime", function()
    local h = google()
    t.truthy(call(
      h,
      creds.from_workload_identity({
        audience = AUD,
        subject_token = "oidc",
        service_account_email = "ci@acme.iam.gserviceaccount.com",
        scopes = { "https://www.googleapis.com/auth/devstorage.read_only" },
        token_lifetime_seconds = 600,
      })
    ))
    t.eq(form(h.calls[1].body).scope, "https://www.googleapis.com/auth/cloud-platform")
    t.eq(h.calls[2].headers.authorization, "Bearer federated-1")
    t.eq(
      h.calls[2].body,
      json.encode({
        scope = json.array({ "https://www.googleapis.com/auth/devstorage.read_only" }),
        lifetime = "600s",
      })
    )
    t.eq(h.calls[3].headers.authorization, "Bearer impersonated-1")
  end)

  t.it("exchanges a fresh subject token once the access token nears expiry", function()
    local h = google()
    local n = { v = 0 }
    local p = creds.from_workload_identity({
      audience = AUD,
      subject_token = function()
        n.v = n.v + 1
        return "oidc-" .. n.v
      end,
    })
    t.truthy(call(h, p))
    t.truthy(call(h, p))
    t.eq(n.v, 1)
    h.advance(3600 - 299)
    t.truthy(call(h, p))
    t.eq(n.v, 2)
    t.eq(form(h.calls[4].body).subject_token, "oidc-2")
    t.eq(h.calls[5].headers.authorization, "Bearer federated-2")
  end)

  t.it("a rejected exchange fails with GCPCredentialsError, without the token", function()
    local h = google({
      handlers = {
        ["sts.googleapis.com"] = function()
          return {
            status = 400,
            body = { error = "invalid_grant", error_description = "bad audience" },
          }
        end,
      },
    })
    local _, err =
      call(h, creds.from_workload_identity({ audience = AUD, subject_token = "oidc-secret-xyz" }))
    t.eq(err.tag, "GCPCredentialsError")
    t.eq(err.status, 400)
    t.match(err.message, "bad audience", true)
    t.no_match(err.message, "oidc-secret-xyz", true)
    t.eq(#h.api(), 0)
  end)

  t.it("a subject token function that fails is a GCPCredentialsError", function()
    local h = google()
    local _, err = call(
      h,
      creds.from_workload_identity({
        audience = AUD,
        subject_token = function()
          return nil, "no token file"
        end,
      })
    )
    t.eq(err.tag, "GCPCredentialsError")
    t.same(h.hosts(), {})
  end)
end)

t.describe("gcp credentials: service account key, access token, provider errors", function()
  t.it("signs Distilled's assertion byte for byte (task 24 golden token)", function()
    local vectors = dofile(t.root .. "/spec/golden/crypto_pk/vectors.lua")
    local v = vectors.tokens.gcp
    local token = assert(creds.sign_assertion({
      client_email = "svc@project.iam.gserviceaccount.com",
      private_key = KEYS.rsa2048.pkcs8,
      private_key_id = "abc123",
    }, "https://oauth2.googleapis.com/token", v.iat))
    t.eq(token, v.token)
  end)

  t.it("a key that is not an RSA PKCS #8 key fails without quoting it", function()
    local h = google()
    local p = creds.from_service_account_key({
      client_email = "svc@p.iam.gserviceaccount.com",
      private_key = "-----BEGIN PRIVATE KEY-----\nAAAA-secret-bytes\n-----END PRIVATE KEY-----\n",
    })
    local _, err = call(h, p)
    t.eq(err.tag, "GCPCredentialsError")
    t.match(err.message, "Could not sign a JWT", true)
    t.no_match(err.message, "secret-bytes", true)
    t.same(h.hosts(), {})
  end)

  t.it("from_service_account_key with scopes and token_url", function()
    local h = google({
      handlers = {
        ["proxy.example.com"] = function()
          return { status = 200, body = { access_token = "sa-1", expires_in = 100 } }
        end,
      },
    })
    local p = creds.from_service_account_key({
      client_email = "svc@p.iam.gserviceaccount.com",
      private_key = secret(KEYS.rsa2048.pkcs8),
      scopes = { "a", "b" },
      token_url = "https://proxy.example.com/token",
      quota_project = "billing",
    })
    t.truthy(call(h, p))
    local claims = assert(jwt.decode(form(h.calls[1].body).assertion))
    t.eq(claims.scope, "a b")
    t.eq(claims.aud, "https://proxy.example.com/token")
    t.eq(h.calls[2].headers.authorization, "Bearer sa-1")
    t.eq(h.calls[2].headers["x-goog-user-project"], "billing")
    -- expires_in 100 is already inside the window: every attempt mints
    t.truthy(call(h, p))
    t.eq(h.calls[3].host, "proxy.example.com")
  end)

  t.it("credentials are resolved per request: a rotating function is called each time", function()
    local h = google()
    local n = { v = 0 }
    local provider = creds.custom(function()
      n.v = n.v + 1
      return { access_token = secret("tok-" .. n.v) }
    end)
    t.truthy(call(h, provider))
    t.truthy(call(h, provider))
    t.eq(h.calls[1].headers.authorization, "Bearer tok-1")
    t.eq(h.calls[2].headers.authorization, "Bearer tok-2")
  end)

  t.it("a provider that fails, raises or returns no token sends nothing", function()
    local h = google()
    local _, e1 = call(
      h,
      creds.custom(function()
        return nil, "nope"
      end)
    )
    t.eq(e1.tag, "GCPCredentialsError")
    local _, e2 = call(
      h,
      creds.custom(function()
        error("boom")
      end)
    )
    t.eq(e2.tag, "GCPCredentialsError")
    t.match(e2.message, "raised", true)
    local _, e3 = call(
      h,
      creds.custom(function()
        return { project = "p" }
      end)
    )
    t.match(e3.message, "no access_token", true)
    t.same(h.hosts(), {})
  end)

  t.it("access_token option, GOOGLE_ACCESS_TOKEN, and from_access_token overrides", function()
    local h =
      google({ env = { GOOGLE_ACCESS_TOKEN = "env-tok", GOOGLE_CLOUD_QUOTA_PROJECT = "qp" } })
    local client = ResourceManager.new({ host = h, retry = "none" })
    t.truthy(client:get_projects({ name = "projects/1" }))
    t.eq(h.calls[1].headers.authorization, "Bearer env-tok")
    -- GOOGLE_ACCESS_TOKEN carries no quota project (Distilled's CredentialsFromEnv)
    t.eq(h.calls[1].headers["x-goog-user-project"], nil)
    client = ResourceManager.new({
      host = h,
      retry = "none",
      access_token = "opt-tok",
      quota_project = "mine",
    })
    t.truthy(client:get_projects({ name = "projects/1" }))
    t.eq(h.calls[2].headers.authorization, "Bearer opt-tok")
    t.eq(h.calls[2].headers["x-goog-user-project"], "mine")
    t.truthy(
      call(h, creds.from_access_token({ access_token = secret("ft"), quota_project = "q2" }))
    )
    t.eq(h.calls[3].headers.authorization, "Bearer ft")
    t.eq(h.calls[3].headers["x-goog-user-project"], "q2")
  end)

  t.it("parse_time reads RFC 3339 times", function()
    t.eq(creds.parse_time("1970-01-01T00:00:00Z"), 0)
    t.eq(creds.parse_time("2023-11-14T22:13:20Z"), 1700000000)
    t.eq(creds.parse_time("2023-11-14T22:13:20.5Z"), 1700000000.5)
    t.eq(creds.parse_time("2023-11-15T00:13:20+02:00"), 1700000000)
    t.eq(creds.parse_time("nope"), nil)
  end)
end)
