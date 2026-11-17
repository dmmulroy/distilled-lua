-- GCP conformance (task 21), step 1: write the cases spec/fixtures/gcp/cases.json from
-- the generated clients. Step 2 is Node (verify/lib/gcp_conform.mjs: what Distilled's
-- GcpProtocol / GoogleWorkspaceProtocol make of each case, into
-- spec/golden/gcp/reference.json); step 3 is spec/gcp_conform_spec.lua (the same cases
-- through the Lua clients, in every runtime, compared with the reference).
--
--   lua verify/lib/gcp_conform_cases.lua <root>
--
-- Requests: for every model of gcp and google_workspace (stable and unstable), two
-- operations picked deterministically (one by a hash of the model name, one that sends a
-- body), with an input that sets every top-level scalar or list-of-scalars member:
-- labels with characters reserved expansion keeps or encodes, query values with spaces
-- and `&`, numbers, booleans, repeated values. Plus hand-written cases for the options
-- (quota project, endpoint override, regional endpoints), payload members, headers.
-- Responses and flows are hand-written (below).
local root = assert(arg[1], "usage: gcp_conform_cases.lua <root>")
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local json = require("distilled.json")
local schema = require("distilled.schema")

local function fnv(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + string.byte(s, i)) % 2147483647
  end
  return h
end

local function ts_name(op_name)
  local s = string.gsub(op_name, "_+$", "")
  return string.lower(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- a value for one member; nil to leave it out
local function value_for(m, registry, greedy)
  local node = schema.resolve(m.schema, registry)
  if not node then
    return nil
  end
  local t = node.t
  if m.bind == "label" then
    if greedy then
      return "projects/p-1/locations/us-central1/things/a b~c:d@e%f"
    end
    return "id x/y?z"
  end
  if t == "string" or t == "timestamp" then
    return "v " .. m.name .. "&=1/é"
  elseif t == "number" then
    return 7
  elseif t == "boolean" then
    return true
  elseif t == "enum" then
    return node.values[#node.values]
  elseif t == "list" then
    local item = schema.resolve(node.item, registry)
    if item and (item.t == "string" or item.t == "enum") then
      local a = item.t == "enum" and item.values[1] or "a 1"
      local b = item.t == "enum" and item.values[#item.values] or "b/2"
      return json.array({ a, b })
    elseif item and item.t == "number" then
      return json.array({ 1, 2.5 })
    end
  end
  return nil
end

local function input_for(op, registry)
  local node = schema.resolve(op.input, registry)
  local input = {}
  for _, m in ipairs(node and node.members or {}) do
    local greedy = string.find(op.uri, "{" .. (m.wire or m.name) .. "+}", 1, true) ~= nil
    local v = value_for(m, registry, greedy)
    if v ~= nil then
      input[m.name] = v
    end
  end
  -- placeholders without a member (recaptchaenterprise {+key})
  for inner in string.gmatch(op.uri, "{([^}]*)}") do
    local key = string.gsub(inner, "%+$", "")
    if input[key] == nil then
      input[key] = "keys/k1"
    end
  end
  return input
end

local requests = {}
local function add_request(c)
  requests[#requests + 1] = c
end

local function services_of(pkg)
  local out = {}
  local index = require(pkg)
  for _, name in ipairs(index.services) do
    out[#out + 1] = { pkg = pkg, service = name, unstable = false, module = pkg .. "." .. name }
  end
  local ok, uindex = pcall(require, pkg .. ".unstable")
  if ok then
    for _, name in ipairs(uindex.services) do
      out[#out + 1] =
        { pkg = pkg, service = name, unstable = true, module = pkg .. ".unstable." .. name }
    end
  end
  return out
end

for _, pkg in ipairs({ "gcp", "google_workspace" }) do
  for _, svc in ipairs(services_of(pkg)) do
    local service = require(svc.module .. ".service")
    local names = {}
    for name in pairs(service.ops) do
      names[#names + 1] = name
    end
    table.sort(names)
    local picks = { names[fnv(svc.module) % #names + 1] }
    for _, name in ipairs(names) do
      local op = service.ops[name]
      if name ~= picks[1] and (op.method == "POST" or op.method == "PATCH") then
        local node = schema.resolve(op.input, service.shapes)
        local bodied = false
        for _, m in ipairs(node.members) do
          bodied = bodied or (m.bind == nil or m.bind == "body")
        end
        if bodied then
          picks[2] = name
          break
        end
      end
    end
    for _, name in ipairs(picks) do
      local op = service.ops[name]
      add_request({
        id = svc.module .. "." .. name,
        pkg = pkg,
        service = svc.service,
        unstable = svc.unstable,
        op = name,
        ts = ts_name(op.name),
        input = input_for(op, service.shapes),
      })
    end
  end
end

-- hand-written request cases: options and the rarer bindings
local function hand(id, pkg, service, op, ts, input, options, unstable)
  add_request({
    id = "hand." .. id,
    pkg = pkg,
    service = service,
    unstable = unstable or false,
    op = op,
    ts = ts,
    input = input,
    options = options,
  })
end
local name = "projects/p/locations/us-central1/endpoints/e1"
hand("quota", "gcp", "storage_v1", "list_buckets", "listBuckets", {
  project = "p",
  maxResults = 5,
}, { quota_project = "billing-p" })
hand("endpoint", "gcp", "pubsub_v1", "list_projects_topics", "listProjectsTopics", {
  project = "projects/p",
}, { endpoint = "http://localhost:8085" })
hand("endpoint_path", "gcp", "storage_v1", "get_buckets", "getBuckets", {
  bucket = "b",
}, { endpoint = "https://proxy.example.com/gcs/" })
hand("endpoint_bad", "gcp", "storage_v1", "get_buckets", "getBuckets", {
  bucket = "b",
}, { endpoint = "not a url" })
hand(
  "regional_required",
  "gcp",
  "aiplatform_v1",
  "get_projects_locations_endpoints",
  "getProjectsLocationsEndpoints",
  { name = name }
)
hand(
  "regional_required_eu",
  "gcp",
  "aiplatform_v1",
  "get_projects_locations_endpoints",
  "getProjectsLocationsEndpoints",
  { name = "projects/p/locations/eu/endpoints/e1" }
)
hand(
  "regional_global",
  "gcp",
  "aiplatform_v1",
  "get_projects_locations_endpoints",
  "getProjectsLocationsEndpoints",
  { name = "projects/p/locations/global/endpoints/e1" }
)
hand(
  "regional_unknown",
  "gcp",
  "aiplatform_v1",
  "get_projects_locations_endpoints",
  "getProjectsLocationsEndpoints",
  { name = "projects/p/locations/mars-north1/endpoints/e1" }
)
hand(
  "regional_never",
  "gcp",
  "aiplatform_v1",
  "get_projects_locations_endpoints",
  "getProjectsLocationsEndpoints",
  { name = name },
  { regional_endpoints = "never" }
)
hand(
  "regional_prefer_off",
  "gcp",
  "run_v2",
  "get_projects_locations_services",
  "getProjectsLocationsServices",
  { name = "projects/p/locations/us-central1/services/s" }
)
hand(
  "regional_prefer",
  "gcp",
  "run_v2",
  "get_projects_locations_services",
  "getProjectsLocationsServices",
  { name = "projects/p/locations/us-central1/services/s" },
  { regional_endpoints = "prefer" }
)
hand(
  "secretmanager",
  "gcp",
  "secretmanager_v1",
  "access_projects_locations_secrets_versions",
  "accessProjectsLocationsSecretsVersions",
  { name = "projects/p/locations/europe-west1/secrets/s/versions/latest" }
)
hand("header", "gcp", "datastore_v1", "lookup_projects", "lookupProjects", {
  projectId = "p",
  ["x-goog-request-params"] = "project_id=p",
  keys = json.array({}),
})
hand("no_body", "gcp", "storage_v1", "insert_buckets", "insertBuckets", { project = "p" })
hand("get_drop_body", "gcp", "compute_v1", "get_instances", "getInstances", {
  project = "p",
  zone = "us-central1-a",
  instance = "i-1",
})
hand("nested_body", "gcp", "storage_v1", "insert_objects", "insertObjects", {
  bucket = "bk",
  name = "dir/file name.txt",
  contentType = "text/plain",
  metadata = { owner = "me", ["k 2"] = "v" },
  acl = json.array({ { entity = "allUsers", role = "READER" } }),
})
hand("workspace", "google_workspace", "gmail_v1", "list_users_messages", "listUsersMessages", {
  userId = "me",
  q = "from:a@b.c is:unread",
  labelIds = json.array({ "INBOX", "UNREAD" }),
  includeSpamTrash = false,
  maxResults = 10,
}, { quota_project = "ignored" })
hand(
  "workspace_body",
  "google_workspace",
  "gmail_v1",
  "modify_users_messages",
  "modifyUsersMessages",
  {
    userId = "me",
    id = "m1",
    addLabelIds = json.array({ "STARRED" }),
  }
)
hand("unstable", "gcp", "compute_beta", "list_instances", "listInstances", {
  project = "p",
  zone = "z",
  filter = 'name = "a b"',
  returnPartialSuccess = true,
}, nil, true)

-- responses: one canned response each, decoded by both
local responses = {}
local function resp(id, pkg, service, op, ts, input, response, validation, unstable)
  responses[#responses + 1] = {
    id = "resp." .. id,
    pkg = pkg,
    service = service,
    unstable = unstable or false,
    op = op,
    ts = ts,
    input = input,
    response = response,
    validation = validation,
  }
end
local function envelope(code, message, status, details)
  return json.encode({
    error = { code = code, message = message, status = status, details = details },
  })
end
local get = { "gcp", "storage_v1", "get_buckets", "getBuckets", { bucket = "b" } }
local function r(id, response, validation, which)
  local w = which or get
  resp(id, w[1], w[2], w[3], w[4], w[5], response, validation, w[6])
end
r("ok", { status = 200, body = '{"name":"b","location":"US","labels":{"a":"1"}}' })
r("ok_empty", { status = 200, body = "" })
r("ok_204", { status = 204 })
r("ok_unknown_field", { status = 200, body = '{"name":"b","futureField":[1,2]}' })
r("ok_strict_bad", { status = 200, body = '{"name":5}' }, "strict")
r("ok_not_json", { status = 200, body = "<html>hi</html>" })
r("not_found", {
  status = 404,
  body = envelope(404, "The specified bucket does not exist.", "NOT_FOUND", {
    { ["@type"] = "type.googleapis.com/google.rpc.ErrorInfo", reason = "notFound" },
  }),
})
r("forbidden", { status = 403, body = envelope(403, "denied", "PERMISSION_DENIED") })
r("bad_request_on_get", { status = 400, body = envelope(400, "bad", "INVALID_ARGUMENT") })
r(
  "unauthorized",
  { status = 401, body = envelope(401, "Request had invalid credentials.", "UNAUTHENTICATED") }
)
r("throttled", {
  status = 429,
  headers = { ["retry-after"] = "7" },
  body = envelope(429, "Quota exceeded", "RESOURCE_EXHAUSTED"),
})
r("unavailable", { status = 503, body = envelope(503, "try later", "UNAVAILABLE") })
r("bad_gateway_html", { status = 502, body = "<html><body>Bad Gateway</body></html>" })
r("unmapped_5xx", { status = 599, body = "" })
r("teapot", { status = 418, body = envelope(418, "short and stout", "TEAPOT", { { x = 1 } }) })
r("teapot_empty", { status = 418, body = "" })
r("teapot_text", { status = 418, body = "I'm a teapot" })
r("no_envelope", { status = 404, body = '{"message":"plain"}' })
local insert =
  { "gcp", "storage_v1", "insert_buckets", "insertBuckets", { project = "p", name = "b" } }
r(
  "conflict",
  { status = 409, body = envelope(409, "You already own this bucket.", "ALREADY_EXISTS") },
  nil,
  insert
)
r(
  "bad_request",
  { status = 400, body = envelope(400, "Invalid bucket name", "INVALID_ARGUMENT") },
  nil,
  insert
)
-- message matchers (com.gcp.protocols#errorMatchers with includes / matches)
local scopes = { "gcp", "adsense_v2", "get_accounts", "getAccounts", { name = "accounts/a" } }
r(
  "scopes_matcher",
  {
    status = 403,
    body = envelope(403, "Request had insufficient authentication scopes.", "PERMISSION_DENIED"),
  },
  nil,
  scopes
)
local iam = {
  "gcp",
  "iam_v1",
  "create_projects_service_accounts",
  "createProjectsServiceAccounts",
  { name = "projects/p", accountId = "sa" },
  true,
}
r(
  "quota_matcher",
  {
    status = 429,
    body = envelope(
      429,
      "Maximum number of Service accounts created per minute per project exceeded",
      "RESOURCE_EXHAUSTED"
    ),
  },
  nil,
  iam
)
r(
  "quota_plain_429",
  { status = 429, body = envelope(429, "slow down", "RESOURCE_EXHAUSTED") },
  nil,
  iam
)
local ws = {
  "google_workspace",
  "gmail_v1",
  "get_users_messages",
  "getUsersMessages",
  { userId = "me", id = "m1" },
}
r(
  "workspace_ok",
  { status = 200, body = '{"id":"m1","threadId":"t1","labelIds":["INBOX"]}' },
  nil,
  ws
)
r(
  "workspace_not_found",
  { status = 404, body = envelope(404, "Requested entity was not found.", "NOT_FOUND") },
  nil,
  ws
)
r("workspace_teapot", { status = 418, body = envelope(418, "teapot", "TEAPOT") }, nil, ws)

-- flows: pagination through pageToken -> nextPageToken
local flows = {
  {
    id = "flow.items_path",
    pkg = "gcp",
    service = "storage_v1",
    op = "list_buckets",
    ts = "listBuckets",
    kind = "items",
    input = { project = "p" },
    responses = {
      { status = 200, body = '{"items":[{"name":"b1"},{"name":"b2"}],"nextPageToken":"t 2"}' },
      { status = 200, body = '{"items":[{"name":"b3"}]}' },
    },
  },
  {
    id = "flow.pages",
    pkg = "gcp",
    service = "storage_v1",
    op = "list_buckets",
    ts = "listBuckets",
    kind = "pages",
    input = { project = "p", maxResults = 2 },
    responses = {
      { status = 200, body = '{"items":[{"name":"b1"}],"nextPageToken":"t2"}' },
      { status = 200, body = '{"items":[],"nextPageToken":""}' },
    },
  },
  {
    id = "flow.no_items_path",
    pkg = "gcp",
    service = "storage_v1",
    op = "list_operations",
    ts = "listOperations",
    kind = "items",
    input = { bucket = "bk" },
    responses = {
      { status = 200, body = '{"operations":[{"name":"o1"}],"nextPageToken":"n"}' },
      { status = 200, body = '{"operations":[{"name":"o2"}]}' },
    },
  },
}

local out = { requests = requests, responses = responses, flows = flows }
local text = assert(json.encode(out, { indent = true }))
local path = root .. "/spec/fixtures/gcp/cases.json"
os.execute("mkdir -p '" .. root .. "/spec/fixtures/gcp'")
local f = assert(io.open(path, "wb"))
f:write(text, "\n")
f:close()
print(
  string.format(
    "wrote %s: %d requests, %d responses, %d flows",
    path,
    #requests,
    #responses,
    #flows
  )
)
