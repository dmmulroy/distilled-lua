-- The generated Neon client (clients/neon/) over the scripted transport. The request
-- expectations are checked by hand against what Distilled's generated TypeScript
-- (distilled/packages/neon/src/services/neon.ts) declares for the same operations; each
-- case names the declaration it follows.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Neon = require("neon")
local service = require("neon.service")

local BASE = "https://console.neon.tech/api/v2"
local KEY = "napi_SPEC-FAKE-KEY"

local function client(responses, extra)
  local host = testing.host({ responses = responses, env = (extra and extra.env) or {} })
  local opts = { host = host, api_key = KEY }
  for k, v in pairs(extra or {}) do
    if k ~= "env" then
      opts[k] = v
    end
  end
  return Neon.new(opts), host
end

local function project_body(id)
  return {
    project = {
      id = id,
      name = "demo",
      platform_id = "aws",
      region_id = "aws-us-east-2",
      pg_version = 17,
      created_at = "2024-01-01T00:00:00Z",
      updated_at = "2024-01-01T00:00:00Z",
    },
  }
end

local function list_item(id)
  return { id = id, name = "p-" .. id, region_id = "aws-us-east-2", pg_version = 17 }
end

t.describe("neon client: generated module", function()
  t.it("require('neon') returns a class built from the generated service", function()
    t.eq(type(Neon.new), "function")
    local n = 0
    for _ in pairs(service.ops) do
      n = n + 1
    end
    t.eq(n, 178)
    local c = Neon.new({ api_key = KEY })
    for _, name in ipairs({
      "get_project",
      "list_projects",
      "list_projects_pages",
      "list_projects_items",
      "create_api_key",
      "list_api_keys",
    }) do
      t.eq(type(c[name]), "function", name)
    end
    t.eq(c.get_project_items, nil)
  end)
end)

t.describe("neon client: get_project", function()
  -- neon.ts getProject: GET /projects/{project_id}, project_id T.Label(), errors
  -- [BadRequest, NotFound, UnknownNeonError]
  t.it("succeeds, sending GET with the label, the bearer header and accept json", function()
    local c, host = client({ { status = 200, body = project_body("p1") } })
    local res, err = c:get_project({ project_id = "p1" })
    t.eq(err, nil)
    t.eq(res.project.id, "p1")
    t.eq(res.project.name, "demo")
    local req = host.requests[1]
    t.eq(req.method, "GET")
    t.eq(req.url, BASE .. "/projects/p1")
    t.eq(req.headers.authorization, "Bearer " .. KEY)
    t.eq(req.body, nil)
  end)

  t.it("escapes the label as a path segment", function()
    local c, host = client({ { status = 200, body = project_body("a/b") } })
    c:get_project({ project_id = "a/b c" })
    t.eq(host.requests[1].url, BASE .. "/projects/a%2Fb%20c")
  end)

  t.it("maps a 404 to the generated NotFound class (BadRequestError, as Distilled)", function()
    local c = client({ { status = 404, body = { code = "", message = "project not found" } } })
    local res, err = c:get_project({ project_id = "nope" })
    t.eq(res, nil)
    t.err(res, err, "NotFound")
    t.eq(err.status, 404)
    t.eq(err.message, "project not found")
    t.truthy(err.categories.BadRequestError)
    t.eq(err.retryable, false)
  end)

  t.it("an undeclared status is the provider's unknown error", function()
    local c = client({ { status = 418, body = { message = "teapot" } } })
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err.tag, "UnknownNeonError")
    t.eq(err.status, 418)
  end)

  t.it("a missing label fails before anything is sent", function()
    local c, host = client({})
    local _, err = c:get_project({})
    t.eq(err.tag, "InvalidInput")
    t.eq(#host.requests, 0)
  end)
end)

t.describe("neon client: list_projects pagination", function()
  -- neon.ts listProjects: cursor mode, inputToken cursor, outputToken pagination.cursor,
  -- items projects; every request member is T.Query()
  t.it("list_projects_items walks two pages with the cursor", function()
    local c, host = client({
      {
        status = 200,
        body = {
          projects = json.array({ list_item("p1"), list_item("p2") }),
          pagination = { cursor = "c1" },
        },
      },
      { status = 200, body = { projects = json.array({ list_item("p3") }) } },
    })
    local items, err = c:list_projects_items({ limit = 2, org_id = "org-1" }):collect()
    t.eq(err, nil)
    t.eq(#items, 3)
    t.eq(items[1].id, "p1")
    t.eq(items[3].id, "p3")
    t.eq(#host.requests, 2)
    t.match(host.requests[1].url, "^" .. BASE:gsub("%p", "%%%0") .. "/projects%?")
    t.match(host.requests[1].url, "limit=2", true)
    t.match(host.requests[1].url, "org_id=org%-1")
    t.no_match(host.requests[1].url, "cursor=", true)
    t.match(host.requests[2].url, "cursor=c1", true)
    t.match(host.requests[2].url, "limit=2", true)
  end)

  t.it("list_projects_pages yields whole responses", function()
    local c = client({
      {
        status = 200,
        body = { projects = json.array({ list_item("p1") }), pagination = { cursor = "c1" } },
      },
      { status = 200, body = { projects = json.array({}) } },
    })
    local pages, err = c:list_projects_pages({}):collect()
    t.eq(err, nil)
    t.eq(#pages, 2)
    t.eq(pages[1].projects[1].id, "p1")
  end)

  t.it("a failing page stops the iterator and records the error", function()
    local c = client({
      {
        status = 200,
        body = { projects = json.array({ list_item("p1") }), pagination = { cursor = "c1" } },
      },
      { status = 401, body = { message = "bad key" } },
    })
    local it = c:list_projects_items({})
    local seen = {}
    for p in it do
      seen[#seen + 1] = p.id
    end
    t.same(seen, { "p1" })
    t.eq(it.err.tag, "Unauthorized")
  end)
end)

t.describe("neon client: bodies, secrets and raw outputs", function()
  -- neon.ts createApiKey: POST /api_keys, key_name in the body; ApiKeyCreateResponse.key
  -- carries T.SensitiveValue
  t.it("create_api_key sends a JSON body and returns the key as a secret", function()
    local c, host = client({
      {
        status = 200,
        body = {
          id = 42,
          key = "napi_RETURNED-SECRET",
          name = "ci",
          created_at = "2024-01-01T00:00:00Z",
          created_by = "u1",
        },
      },
    })
    local res, err = c:create_api_key({ key_name = "ci" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, BASE .. "/api_keys")
    t.same(json.decode(req.body), { key_name = "ci" })
    t.eq(req.headers["content-type"], "application/json")
    t.truthy(secret.is(res.key))
    t.eq(tostring(res.key), "<redacted>")
    t.eq(secret.unwrap(res.key), "napi_RETURNED-SECRET")
    t.eq(res.name, "ci")
  end)

  -- neon.ts createProject: POST /projects, { project: CreateProjectRequestProject }
  t.it("create_project nests the project object in the body", function()
    local c, host = client({ { status = 200, body = project_body("p9") } })
    local res, err = c:create_project({ project = { name = "new", region_id = "aws-us-east-2" } })
    t.eq(err, nil)
    t.eq(res.project.id, "p9")
    t.same(
      json.decode(host.requests[1].body),
      { project = { name = "new", region_id = "aws-us-east-2" } }
    )
  end)

  -- neon.ts updateProjectBranch: PATCH, two labels, branch in the body
  t.it("update_project_branch fills two labels and the body", function()
    local c, host = client({ { status = 200, body = { branch = { id = "br-1" } } } })
    local _, err = c:update_project_branch({
      project_id = "p1",
      branch_id = "br-1",
      branch = { name = "renamed" },
    })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.method, "PATCH")
    t.eq(req.url, BASE .. "/projects/p1/branches/br-1")
    t.same(json.decode(req.body), { branch = { name = "renamed" } })
  end)

  -- neon.ts ListApiKeysResponse = ListApiKeysResponseBodyList (rawResponse)
  t.it("list_api_keys: the whole body is the output (rawResponse)", function()
    local c = client({
      {
        status = 200,
        body = json.array({
          { id = 1, name = "a", created_at = "x", created_by = { id = "u", name = "n" } },
          { id = 2, name = "b", created_at = "x", created_by = { id = "u", name = "n" } },
        }),
      },
    })
    local keys, err = c:list_api_keys({})
    t.eq(err, nil)
    t.eq(#keys, 2)
    t.eq(keys[2].name, "b")
  end)

  -- neon.ts GetProjectBranchBucketObjectResponse = Uint8Array (BinaryResponse)
  t.it("get_project_branch_bucket_object returns the raw bytes", function()
    local bytes = "PK\3\4\0\255binary"
    local c, host = client({
      { status = 200, headers = { ["content-type"] = "application/octet-stream" }, body = bytes },
    })
    local res, err = c:get_project_branch_bucket_object({
      project_id = "p1",
      branch_id = "br-1",
      bucket_name = "files",
      object_key = "dir/a.zip",
    })
    t.eq(err, nil)
    t.eq(res, bytes)
    t.eq(
      host.requests[1].url,
      BASE .. "/projects/p1/branches/br-1/buckets/files/objects/dir%2Fa.zip/download"
    )
  end)

  -- neon.ts CreateProjectBranchFunctionDeploymentRequest: zip (Blob) and environment
  -- (sensitive string) as multipart/form-data parts (task 08; was refused before)
  t.it("create_project_branch_function_deployment sends a multipart body", function()
    local multipart = require("distilled.multipart")
    local distilled = require("distilled")
    local c, host = client(
      { { status = 200, body = { deployment = { id = "dep-1" } } } },
      { random = testing.random(7) }
    )
    local res, err = c:create_project_branch_function_deployment({
      project_id = "p1",
      branch_id = "br-1",
      slug = "fn",
      zip = distilled.file({ data = "PK\3\4\0\255", filename = "bundle.zip" }),
      runtime = "nodejs24",
      environment = secret('{"KEY":"VALUE"}'),
    })
    t.eq(err, nil)
    t.eq(res.deployment.id, "dep-1")
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, BASE .. "/projects/p1/branches/br-1/functions/fn/deployments")
    local boundary =
      string.match(req.headers["content-type"], "^multipart/form%-data; boundary=(.+)$")
    -- task 09: the boundary comes from the client's host.random (deterministic here)
    t.eq(boundary, multipart.boundary(testing.random(7)))
    t.eq(
      req.body,
      "--"
        .. boundary
        .. '\r\nContent-Disposition: form-data; name="zip"; filename="bundle.zip"\r\n'
        .. "Content-Type: application/octet-stream\r\n\r\nPK\3\4\0\255\r\n--"
        .. boundary
        .. '\r\nContent-Disposition: form-data; name="runtime"\r\n\r\nnodejs24\r\n--'
        .. boundary
        .. '\r\nContent-Disposition: form-data; name="environment"\r\n\r\n{"KEY":"VALUE"}\r\n--'
        .. boundary
        .. "--\r\n"
    )
    t.no_match(req.body, KEY, true)
  end)
end)

t.describe("neon client: spans from the telemetry traits", function()
  -- neon.ts TELEMETRY { system, prefix "Neon", service "Neon", labels "neon" } and
  -- span: "GetProject"; the model's trait names Neon.GetProject, Neon/GetProject
  t.it("get_project's operation span carries Distilled's names and attributes", function()
    local trace = require("distilled.trace")
    local memory = trace.exporters.memory()
    local c = client({
      { status = 200, headers = { ["x-request-id"] = "req-1" }, body = project_body("p1") },
    }, { tracing = { level = "operation", exporter = memory } })
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err, nil)
    t.eq(#memory.spans, 1)
    local span = memory.spans[1]
    t.eq(span.name, "Neon.GetProject")
    t.eq(span.kind, "client")
    local a = span.attributes
    t.eq(a["rpc.system.name"], "neon-api")
    t.eq(a["rpc.method"], "Neon/GetProject")
    t.eq(a["url.template"], "/projects/{project_id}")
    t.eq(a["neon.project_id"], "p1")
    t.eq(a["http.request.method"], "GET")
    t.eq(a["http.response.status_code"], 200)
    t.same(a["http.response.header.x-request-id"], { "req-1" })
  end)

  t.it("a failed call's span records the error tag and the error its trace id", function()
    local trace = require("distilled.trace")
    local memory = trace.exporters.memory()
    local c = client(
      { { status = 404, body = { message = "gone" } } },
      { tracing = { level = "operation", exporter = memory } }
    )
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err.tag, "NotFound")
    t.eq(memory.spans[1].attributes["error.type"], "NotFound")
    t.eq(err.trace_id, memory.spans[1].trace_id)
  end)
end)

t.describe("neon client: configuration", function()
  t.it("base_url overrides the default", function()
    local c, host = client(
      { { status = 200, body = project_body("p1") } },
      { base_url = "http://127.0.0.1:8080/api/v2" }
    )
    c:get_project({ project_id = "p1" })
    t.eq(host.requests[1].url, "http://127.0.0.1:8080/api/v2/projects/p1")
  end)

  t.it("NEON_API_BASE_URL and NEON_API_KEY come from the host's environment", function()
    local host = testing.host({
      responses = { { status = 200, body = project_body("p1") } },
      env = { NEON_API_KEY = "napi_FROM-ENV", NEON_API_BASE_URL = "https://neon.example.test/v2" },
    })
    local c = Neon.new({ host = host })
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err, nil)
    t.eq(host.requests[1].url, "https://neon.example.test/v2/projects/p1")
    t.eq(host.requests[1].headers.authorization, "Bearer napi_FROM-ENV")
  end)

  t.it("no key anywhere is a ConfigError naming api_key, and nothing is sent", function()
    local host = testing.host({ responses = {} })
    local c = Neon.new({ host = host })
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "api_key")
    t.eq(#host.requests, 0)
  end)

  t.it("the key never appears in an error", function()
    local c = client({ { status = 500, body = { message = "boom" } } }, { retry = "none" })
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err.tag, "InternalServerError")
    t.no_match(tostring(err), KEY, true)
    t.no_match(json.encode(err.headers or {}) or "", KEY, true)
  end)
end)
