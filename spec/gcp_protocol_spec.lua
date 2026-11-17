-- The GCP and Google Workspace protocols (distilled.gcp.protocol, distilled.gcp.workspace)
-- through generated clients and a scripted transport. Ported from Distilled's
-- packages/gcp/test/protocol.test.ts and packages/google-workspace/test/protocol.test.ts,
-- plus retries (credentials per attempt), GOOGLE_API_ENDPOINT and option misuse.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local creds = require("distilled.gcp.credentials")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path
local SecretManager = require("gcp.secretmanager_v1")
local Storage = require("gcp.storage_v1")
local Datastore = require("gcp.datastore_v1")
local Run = require("gcp.run_v2")
local Drive = require("google_workspace.drive_v3")
local Gmail = require("google_workspace.gmail_v1")
local Tasks = require("google_workspace.tasks_v1")
local People = require("google_workspace.people_v1")

local TOKEN = "ya29.test-token"

-- fake(status, body, headers) -> host; host.requests lists what was sent
local function fake(status, body, headers, env)
  local responses = {}
  for i = 1, 4 do
    responses[i] =
      { status = status or 200, body = body == nil and "{}" or body, headers = headers }
  end
  return testing.host({ responses = responses, env = env or {} })
end

local function new(Class, h, extra)
  local opts = { host = h, retry = "none", access_token = secret(TOKEN) }
  for k, v in pairs(extra or {}) do
    opts[k] = v
  end
  return Class.new(opts)
end

local function query_of(u)
  return string.match(u, "%?(.*)$")
end
local function origin_of(u)
  return string.match(u, "^(https?://[^/]+)")
end

local function envelope(code, status, message, details)
  return json.encode({
    error = { code = code, status = status, message = message, details = details },
  })
end

t.describe("gcp protocol: request encoding", function()
  t.it("sends the access token as a Bearer Authorization header", function()
    local h = fake(200, '{"name":"projects/p/secrets/s"}')
    t.truthy(
      new(SecretManager, h):get_projects_locations_secrets({ name = "projects/p/secrets/s" })
    )
    t.eq(h.requests[1].headers.authorization, "Bearer " .. TOKEN)
  end)

  t.it("resolves credentials per attempt: a retried request gets the rotated token", function()
    local h = testing.host({
      responses = {
        { status = 503, body = envelope(503, "UNAVAILABLE", "later") },
        { status = 200, body = "{}" },
      },
    })
    local n = { v = 0 }
    local client = SecretManager.new({
      host = h,
      credentials = creds.custom(function()
        n.v = n.v + 1
        return { access_token = secret("token-" .. n.v) }
      end),
    })
    -- a GET retries by default (a DELETE has max_attempts = 1 from Google's retry config)
    t.truthy(client:get_projects_locations_secrets({ name = "projects/p/secrets/s" }))
    t.eq(h.requests[1].headers.authorization, "Bearer token-1")
    t.eq(h.requests[2].headers.authorization, "Bearer token-2")
    t.eq(#h.sleeps, 1)
  end)

  t.it("surfaces a credentials failure without sending a request", function()
    local h = fake()
    local client = SecretManager.new({
      host = h,
      retry = "none",
      credentials = creds.custom(function()
        return nil, require("distilled.gcp.errors").credentials("token exchange rejected")
      end),
    })
    local v, err = client:delete_projects_secrets({ name = "projects/p/secrets/s" })
    t.eq(v, nil)
    t.eq(err.tag, "GCPCredentialsError")
    t.eq(err.message, "token exchange rejected")
    t.eq(#h.requests, 0)
  end)

  t.it("with no credentials at all, the ADC error names the fix (no request)", function()
    local h = fake(404, "", nil, { CLOUDSDK_CONFIG = "/nonexistent-distilled-21" })
    h.read_file = function()
      return nil
    end
    local _, err = Storage.new({ host = h, retry = "none" })
      :get_objects({ bucket = "b", object = "o" })
    t.eq(err.tag, "GCPCredentialsError")
    t.match(err.message, "gcloud auth application-default login", true)
    -- only the metadata-server probe was sent
    t.eq(#h.requests, 1)
    t.match(h.requests[1].url, "^http://metadata.google.internal/")
  end)

  t.it("prefixes the per-service base URL including its service path", function()
    local h = fake()
    t.truthy(new(Storage, h):get_objects({ bucket = "my-bucket", object = "file.txt" }))
    t.eq(h.requests[1].method, "GET")
    t.eq(h.requests[1].url, "https://storage.googleapis.com/storage/v1/b/my-bucket/o/file.txt")
  end)

  t.it("{+name} reserved expansion keeps '/' but encodes other characters", function()
    local h = fake()
    t.truthy(
      new(SecretManager, h):get_projects_locations_secrets({ name = "projects/p/secrets/a b%" })
    )
    t.eq(h.requests[1].url, "https://secretmanager.googleapis.com/v1/projects/p/secrets/a%20b%25")
  end)

  t.it("plain {param} labels are fully percent-encoded, including '/'", function()
    local h = fake()
    t.truthy(new(Storage, h):get_objects({ bucket = "b", object = "dir/sub file.txt" }))
    t.eq(h.requests[1].url, "https://storage.googleapis.com/storage/v1/b/b/o/dir%2Fsub%20file.txt")
  end)

  t.it("a missing label fails before sending", function()
    local h = fake()
    local _, err = new(Storage, h):get_objects({ bucket = "b" })
    t.eq(err.tag, "InvalidInput")
    t.eq(#h.requests, 0)
  end)

  t.it("scalar query members are stringified and absent ones omitted", function()
    local h = fake(200, '{"secrets":[]}')
    t.truthy(new(SecretManager, h):list_projects_secrets({
      parent = "projects/p",
      pageSize = 10,
      filter = "labels.env=prod",
    }))
    t.eq(
      h.requests[1].url,
      "https://secretmanager.googleapis.com/v1/projects/p/secrets?filter=labels.env%3Dprod&pageSize=10"
    )
  end)

  t.it("array query members are sent as repeated key=value pairs", function()
    local h = fake(200, '{"permissions":[]}')
    t.truthy(new(Storage, h):test_iam_permissions_buckets({
      bucket = "b",
      permissions = { "storage.buckets.get", "storage.objects.list" },
    }))
    t.eq(
      query_of(h.requests[1].url),
      "permissions=storage.buckets.get&permissions=storage.objects.list"
    )
  end)

  t.it("request body fields are top-level input fields", function()
    local h = fake(200, '{"name":"projects/p/secrets/s"}')
    t.truthy(new(SecretManager, h):create_projects_secrets({
      parent = "projects/p",
      secretId = "s",
      replication = { automatic = json.object({}) },
      labels = { env = "test" },
    }))
    local r = h.requests[1]
    t.eq(r.method, "POST")
    t.eq(r.url, "https://secretmanager.googleapis.com/v1/projects/p/secrets?secretId=s")
    t.eq(r.headers["content-type"], "application/json")
    t.eq(r.body, '{"labels":{"env":"test"},"replication":{"automatic":{}}}')
  end)

  t.it("requests without a body member send no body", function()
    local h = fake()
    t.truthy(
      new(SecretManager, h):delete_projects_secrets({
        name = "projects/p/secrets/s",
        etag = '"abc"',
      })
    )
    t.eq(h.requests[1].method, "DELETE")
    t.truthy(h.requests[1].body == nil or h.requests[1].body == "")
    t.eq(query_of(h.requests[1].url), "etag=%22abc%22")
  end)

  t.it("header members are sent as lower-cased request headers", function()
    local h = fake()
    t.truthy(new(Datastore, h):allocate_ids_projects({
      projectId = "p",
      requestParams = "project_id=p",
      keys = json.array({}),
    }))
    t.eq(h.requests[1].url, "https://datastore.googleapis.com/v1/projects/p:allocateIds")
    t.eq(h.requests[1].headers["x-goog-request-params"], "project_id=p")
  end)

  t.it("the quota project option sets X-Goog-User-Project", function()
    local h = fake()
    t.truthy(
      new(Storage, h, { quota_project = "billing" }):get_objects({ bucket = "b", object = "o" })
    )
    t.eq(h.requests[1].headers["x-goog-user-project"], "billing")
  end)
end)

t.describe("gcp protocol: endpoint selection", function()
  local regional = "projects/p/locations/europe-west1/secrets/s"

  t.it("region-required services go to the regional host by default", function()
    local h = fake()
    t.truthy(new(SecretManager, h):get_projects_locations_secrets({ name = regional }))
    t.eq(h.requests[1].url, "https://secretmanager.europe-west1.rep.googleapis.com/v1/" .. regional)
  end)

  t.it("global and wildcard locations stay on the global host", function()
    for _, loc in ipairs({ "global", "-" }) do
      local h = fake()
      t.truthy(new(SecretManager, h):get_projects_locations_secrets({
        name = "projects/p/locations/" .. loc .. "/secrets/s",
      }))
      t.eq(origin_of(h.requests[1].url), "https://secretmanager.googleapis.com")
    end
  end)

  t.it("other services stay global unless regional_endpoints is 'prefer'", function()
    local name = "projects/p/locations/us-central1/services/api"
    local h = fake()
    t.truthy(new(Run, h):get_projects_locations_services({ name = name }))
    t.eq(origin_of(h.requests[1].url), "https://run.googleapis.com")
    h = fake()
    t.truthy(
      new(Run, h, { regional_endpoints = "prefer" }):get_projects_locations_services({ name = name })
    )
    t.eq(h.requests[1].url, "https://run.us-central1.rep.googleapis.com/v2/" .. name)
  end)

  t.it("regional_endpoints 'never' keeps region-required services global", function()
    local h = fake()
    t.truthy(
      new(SecretManager, h, { regional_endpoints = "never" }):get_projects_locations_secrets({
        name = regional,
      })
    )
    t.eq(origin_of(h.requests[1].url), "https://secretmanager.googleapis.com")
  end)

  t.it("an unknown regional_endpoints mode is a ConfigError", function()
    local h = fake()
    local _, err =
      new(SecretManager, h, { regional_endpoints = "always" }):get_projects_locations_secrets({
        name = regional,
      })
    t.eq(err.tag, "ConfigError")
    t.eq(#h.requests, 0)
  end)

  t.it("an unpublished location falls back to the global host", function()
    local h = fake()
    t.truthy(new(SecretManager, h):get_projects_locations_secrets({
      name = "projects/p/locations/mars-north1/secrets/s",
    }))
    t.eq(origin_of(h.requests[1].url), "https://secretmanager.googleapis.com")
  end)

  t.it("an endpoint override replaces the origin and keeps the service path", function()
    local h = fake()
    t.truthy(new(Storage, h, { endpoint = "http://localhost:4443/proxy/" }):get_objects({
      bucket = "b",
      object = "o",
    }))
    t.eq(h.requests[1].url, "http://localhost:4443/proxy/storage/v1/b/b/o/o")
  end)

  t.it("an endpoint override wins over regional routing", function()
    local h = fake()
    t.truthy(
      new(SecretManager, h, { endpoint = "http://localhost:9000" }):get_projects_locations_secrets({
        name = regional,
      })
    )
    t.eq(h.requests[1].url, "http://localhost:9000/v1/" .. regional)
  end)

  t.it("GOOGLE_API_ENDPOINT is the default override; an empty one is ignored", function()
    local h = fake(200, "{}", nil, { GOOGLE_API_ENDPOINT = "http://localhost:8085" })
    t.truthy(new(Storage, h):get_objects({ bucket = "b", object = "o" }))
    t.eq(h.requests[1].url, "http://localhost:8085/storage/v1/b/b/o/o")
    h = fake(200, "{}", nil, { GOOGLE_API_ENDPOINT = "" })
    t.truthy(new(Storage, h):get_objects({ bucket = "b", object = "o" }))
    t.eq(origin_of(h.requests[1].url), "https://storage.googleapis.com")
  end)

  t.it("an endpoint that is not an absolute URL is a ConfigError", function()
    local h = fake()
    local _, err =
      new(Storage, h, { endpoint = "not a url" }):get_objects({ bucket = "b", object = "o" })
    t.eq(err.tag, "ConfigError")
    t.eq(
      err.message,
      'GCP endpoint override must be an absolute URL (e.g. http://localhost:8085), got "not a url"'
    )
    t.eq(#h.requests, 0)
  end)
end)

t.describe("gcp protocol: error envelope", function()
  local name = "projects/p/secrets/s/versions/1"
  local function access(status, body, headers)
    local h = fake(status, body, headers)
    local v, err = new(SecretManager, h):access_projects_secrets_versions({ name = name })
    t.eq(v, nil)
    return err
  end

  t.it("a declared status matcher yields the operation's class with envelope fields", function()
    local details = json.array({
      { ["@type"] = "type.googleapis.com/google.rpc.ResourceInfo", resourceName = name },
    })
    local err =
      access(404, envelope(404, "NOT_FOUND", "Secret [s] not found or has no versions.", details))
    t.eq(err.tag, "NotFound")
    t.eq(err.code, 404)
    t.eq(err.status, 404)
    t.eq(err.rpc_status, "NOT_FOUND")
    t.eq(err.message, "Secret [s] not found or has no versions.")
    t.eq(json.encode(err.details), json.encode(details))
    t.truthy(err.categories.BadRequestError)
  end)

  t.it("a message matcher wins over the bare status matcher", function()
    local message = "Secret Version [" .. name .. "] is in DISABLED state."
    local err = access(400, envelope(400, "FAILED_PRECONDITION", message))
    t.eq(err.tag, "SecretVersionNotEnabled")
    t.eq(err.message, message)
    t.eq(err.rpc_status, "FAILED_PRECONDITION")
    t.eq(err.code, 400)
  end)

  t.it("undeclared statuses fall back to the status map with the envelope in the body", function()
    local err = access(
      429,
      envelope(429, "RESOURCE_EXHAUSTED", "Quota exceeded for quota metric 'Requests'."),
      { ["retry-after"] = "7" }
    )
    t.eq(err.tag, "TooManyRequests")
    t.eq(err.message, "Quota exceeded for quota metric 'Requests'.")
    t.eq(err.body.error.status, "RESOURCE_EXHAUSTED")
    t.eq(err.retry_after, 7)
    t.truthy(err.retryable)
  end)

  t.it("unmapped statuses become UnknownGCPError carrying status, code and body", function()
    local body = '{"error":{"code":418,"message":"teapot","status":"UNKNOWN"}}'
    local err = access(418, body)
    t.eq(err.tag, "UnknownGCPError")
    t.eq(err.status, 418)
    t.eq(err.code, "UNKNOWN")
    t.eq(err.message, "teapot")
    t.eq(json.encode(err.body), body)
  end)

  t.it("a non-JSON error body becomes the message", function()
    local err = access(418, "<html>bad gateway</html>")
    t.eq(err.tag, "UnknownGCPError")
    t.eq(err.status, 418)
    t.eq(err.message, "<html>bad gateway</html>")
    t.eq(err.body, "<html>bad gateway</html>")
  end)

  t.it("an empty or envelope-less error body uses the HTTP status as message", function()
    for _, body in ipairs({ "", '{"unexpected":true}' }) do
      local err = access(404, body)
      t.eq(err.tag, "NotFound")
      t.eq(err.message, "404")
    end
  end)

  t.it("an unmapped 5xx is a retryable InternalServerError", function()
    local err = access(599, "")
    t.eq(err.tag, "InternalServerError")
    t.truthy(err.retryable)
  end)

  t.it("no secret reaches the error", function()
    local err = access(403, envelope(403, "PERMISSION_DENIED", "denied"))
    t.no_match(json.encode(err.body) .. tostring(err.message), TOKEN, true)
    t.no_match(tostring(err), TOKEN, true)
  end)
end)

t.describe("gcp protocol: success decoding", function()
  t.it("a JSON body is returned verbatim", function()
    local h = fake(200, '{"labels":{"env":"prod"},"name":"projects/p/secrets/s"}')
    local v =
      new(SecretManager, h):get_projects_locations_secrets({ name = "projects/p/secrets/s" })
    t.eq(json.encode(v), '{"labels":{"env":"prod"},"name":"projects/p/secrets/s"}')
  end)

  t.it("an empty body decodes to {} (200 and 204)", function()
    for _, status in ipairs({ 200, 204 }) do
      local h = fake(status, "")
      local v, err =
        new(SecretManager, h):delete_projects_secrets({ name = "projects/p/secrets/s" })
      t.eq(err, nil)
      t.eq(json.encode(v), "{}")
    end
  end)

  t.it("a 200 response whose body is JSON null returns null", function()
    local h = fake(200, "null")
    local v, err = new(SecretManager, h):delete_projects_secrets({ name = "projects/p/secrets/s" })
    t.eq(err, nil)
    t.eq(v, json.null)
  end)

  t.it("strict validation fails a mismatched payload with GCPParseError", function()
    local h = fake(200, '{"name":42}')
    local _, err = new(SecretManager, h, { validation = "strict" }):get_projects_locations_secrets({
      name = "projects/p/secrets/s",
    })
    t.eq(err.tag, "GCPParseError")
    t.truthy(err.categories.ParseError)
  end)

  t.it("a non-JSON success body is returned as text in lenient mode", function()
    local h = fake(200, "plain")
    t.eq(
      new(SecretManager, h):get_projects_locations_secrets({ name = "projects/p/secrets/s" }),
      "plain"
    )
  end)
end)

t.describe("google workspace protocol", function()
  t.it("bearer token, per-request credentials, no quota project header", function()
    local h = fake()
    t.truthy(new(Drive, h):get_files({ fileId = "f" }))
    t.eq(h.requests[1].headers.authorization, "Bearer " .. TOKEN)
    t.eq(h.requests[1].headers["x-goog-user-project"], nil)
    local n = { v = 0 }
    local client = Drive.new({
      host = h,
      retry = "none",
      credentials = creds.custom(function()
        n.v = n.v + 1
        return { access_token = "t" .. n.v, quota_project = "ignored" }
      end),
    })
    t.truthy(client:get_files({ fileId = "f" }))
    t.truthy(client:get_files({ fileId = "f" }))
    t.eq(h.requests[2].headers.authorization, "Bearer t1")
    t.eq(h.requests[3].headers.authorization, "Bearer t2")
    t.eq(h.requests[3].headers["x-goog-user-project"], nil)
  end)

  t.it("without credentials: GOOGLE_ACCESS_TOKEN, else a ConfigError", function()
    local h = fake(200, "{}", nil, { GOOGLE_ACCESS_TOKEN = "env-tok" })
    t.truthy(Drive.new({ host = h, retry = "none" }):get_files({ fileId = "f" }))
    t.eq(h.requests[1].headers.authorization, "Bearer env-tok")
    h = fake()
    local _, err = Drive.new({ host = h, retry = "none" }):get_files({ fileId = "f" })
    t.eq(err.tag, "ConfigError")
    t.eq(#h.requests, 0)
  end)

  t.it("uses each API's own base URL (host-only and host+service-path)", function()
    local h = fake()
    t.truthy(new(Drive, h):get_files({ fileId = "f" }))
    t.eq(h.requests[1].url, "https://www.googleapis.com/drive/v3/files/f")
    h = fake()
    t.truthy(new(Gmail, h):list_users_messages({ userId = "me" }))
    t.eq(h.requests[1].url, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
  end)

  t.it("plain labels are fully encoded; {+param} keeps '/'", function()
    local h = fake()
    t.truthy(new(Tasks, h):delete_tasks({ tasklist = "list/1", task = "a b" }))
    t.eq(h.requests[1].method, "DELETE")
    t.eq(h.requests[1].url, "https://tasks.googleapis.com/tasks/v1/lists/list%2F1/tasks/a%20b")
    h = fake()
    t.truthy(new(People, h):get_people({ resourceName = "people/c 1", personFields = "names" }))
    t.eq(h.requests[1].url, "https://people.googleapis.com/v1/people/c%201?personFields=names")
  end)

  t.it("query members: booleans/numbers stringified, arrays repeated, dotted names kept", function()
    local h = fake()
    t.truthy(new(Gmail, h):list_users_messages({
      userId = "me",
      labelIds = { "INBOX", "UNREAD" },
      includeSpamTrash = false,
      maxResults = 5,
    }))
    t.eq(
      query_of(h.requests[1].url),
      "includeSpamTrash=false&labelIds=INBOX&labelIds=UNREAD&maxResults=5"
    )
    h = fake()
    t.truthy(new(People, h):get_people({
      resourceName = "people/me",
      ["requestMask.includeField"] = "person.names",
    }))
    t.eq(query_of(h.requests[1].url), "requestMask.includeField=person.names")
  end)

  t.it("request body fields are the JSON body; GET sends none", function()
    local h = fake()
    t.truthy(new(Tasks, h):insert_tasklists({ title = "Groceries" }))
    t.eq(h.requests[1].method, "POST")
    t.eq(h.requests[1].url, "https://tasks.googleapis.com/tasks/v1/users/@me/lists")
    t.eq(h.requests[1].headers["content-type"], "application/json")
    t.eq(h.requests[1].body, '{"title":"Groceries"}')
    h = fake()
    t.truthy(new(Drive, h):get_files({ fileId = "f" }))
    t.truthy(h.requests[1].body == nil or h.requests[1].body == "")
  end)

  t.it("workspace clients have no endpoint, quota_project or regional options", function()
    t.raises(function()
      Drive.new({ endpoint = "http://x" })
    end, "endpoint")
  end)

  local function get_files(status, body, headers)
    local h = fake(status, body, headers)
    local v, err = new(Drive, h):get_files({ fileId = "f" })
    t.eq(v, nil)
    return err
  end

  t.it("dispatches by HTTP status and fills envelope status and details", function()
    local details = json.array({
      { ["@type"] = "type.googleapis.com/google.rpc.ErrorInfo", reason = "notFound" },
    })
    local err = get_files(404, envelope(404, "NOT_FOUND", "File not found: f.", details))
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "File not found: f.")
    t.eq(err.rpc_status, "NOT_FOUND")
    t.eq(json.encode(err.details), json.encode(details))
  end)

  t.it("403 surfaces as Forbidden", function()
    local h = fake(403, envelope(403, "PERMISSION_DENIED", "Insufficient Permission"))
    local _, err = new(Tasks, h):delete_tasks({ tasklist = "l", task = "t" })
    t.eq(err.tag, "Forbidden")
    t.eq(err.message, "Insufficient Permission")
    t.eq(err.rpc_status, "PERMISSION_DENIED")
  end)

  t.it("retryable statuses carry Retry-After", function()
    local err =
      get_files(429, envelope(429, "RESOURCE_EXHAUSTED", "slow down"), { ["retry-after"] = "3" })
    t.eq(err.tag, "TooManyRequests")
    t.eq(err.retry_after, 3)
    t.eq(err.message, "slow down")
    t.eq(err.body.error.status, "RESOURCE_EXHAUSTED")
  end)

  t.it("a non-JSON error body becomes the message; an empty one the status", function()
    local err = get_files(500, "Internal Error")
    t.eq(err.tag, "InternalServerError")
    t.eq(err.message, "Internal Error")
    err = get_files(404, "")
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "404")
  end)

  t.it("unmapped statuses become UnknownGoogleWorkspaceError", function()
    local body = '{"error":{"code":418,"message":"teapot","status":"UNKNOWN"}}'
    local err = get_files(418, body)
    t.eq(err.tag, "UnknownGoogleWorkspaceError")
    t.eq(err.status, 418)
    t.eq(err.code, "UNKNOWN")
    t.eq(err.message, "teapot")
    t.eq(json.encode(err.body), body)
    err = get_files(418, "teapot")
    t.eq(err.tag, "UnknownGoogleWorkspaceError")
    t.eq(err.message, "teapot")
    t.eq(err.body, "teapot")
  end)

  t.it("success: verbatim JSON, {} for empty 200 and 204, null for null", function()
    local h = fake(200, '{"id":"f","mimeType":"text/plain","name":"doc.txt"}')
    t.eq(
      json.encode(new(Drive, h):get_files({ fileId = "f" })),
      '{"id":"f","mimeType":"text/plain","name":"doc.txt"}'
    )
    for _, status in ipairs({ 200, 204 }) do
      h = fake(status, "")
      t.eq(json.encode(new(Tasks, h):delete_tasks({ tasklist = "l", task = "t" })), "{}")
    end
    h = fake(200, "null")
    t.eq(new(Tasks, h):delete_tasks({ tasklist = "l", task = "t" }), json.null)
  end)

  t.it("strict validation fails a mismatched payload with GoogleWorkspaceParseError", function()
    local h = fake(200, '{"id":42}')
    local _, err = new(Drive, h, { validation = "strict" }):get_files({ fileId = "f" })
    t.eq(err.tag, "GoogleWorkspaceParseError")
  end)
end)
