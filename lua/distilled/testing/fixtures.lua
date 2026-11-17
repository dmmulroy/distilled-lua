-- A small fake service for specs, shaped like the real Neon model (models/neon/neon.json):
-- the same operation names, URIs, bindings, pagination trait and error matchers, cut
-- down to what the layer 2-6 specs need.
--
--   local fixtures = require("distilled.testing.fixtures")
--   local service = fixtures.service()          -- a fresh service descriptor
--   service.ops.get_project, service.shapes, service.errors
--   fixtures.bodies.project("p1")               -- canned wire bodies (tables)
--
-- Operations:
--   get_project       GET    /projects/{project_id}            label; BadRequest, NotFound
--   list_projects     GET    /projects                         query; cursor pagination
--   create_project    POST   /projects                         JSON body; Locked matcher
--   update_branch     PATCH  /projects/{project_id}/branches/{branch_id}
--                                                              2 labels, header, renamed body
--   create_api_key    POST   /api_keys                         sensitive output member `key`
--   get_bucket_object GET    /projects/{project_id}/objects/{key+}   greedy label, raw output
local S = require("distilled.schema")
local errors = require("distilled.errors")
local json = require("distilled.json")

local fixtures = {}

local function m(spec)
  return S.member(spec)
end

function fixtures.shapes()
  local shapes = {}
  shapes.Project = S.struct({
    name = "Project",
    members = {
      m({ name = "id", schema = S.string, required = true }),
      m({ name = "name", schema = S.string, required = true }),
      m({ name = "region_id", schema = S.string, required = true }),
      m({ name = "created_at", schema = S.timestamp }),
      m({ name = "pg_version", schema = S.number }),
      m({
        name = "effective_project_permission",
        schema = S.enum({ "admin", "member" }),
        nullable = true,
      }),
      m({ name = "settings", schema = S.ref("ProjectSettings") }),
    },
  })
  shapes.ProjectSettings = S.struct({
    name = "ProjectSettings",
    members = {
      m({ name = "allowed_ips", schema = S.list(S.string) }),
      m({ name = "quota", schema = S.map(S.number) }),
    },
  })
  shapes.ProjectResponse = S.struct({
    name = "ProjectResponse",
    members = { m({ name = "project", schema = S.ref("Project"), required = true }) },
  })
  shapes.ListProjectsResponse = S.struct({
    name = "ListProjectsResponse",
    members = {
      m({ name = "projects", schema = S.list(S.ref("Project")), required = true }),
      m({ name = "pagination", schema = S.ref("Pagination") }),
    },
  })
  shapes.Pagination = S.struct({
    name = "Pagination",
    members = { m({ name = "cursor", schema = S.string, required = true }) },
  })
  shapes.ProjectCreateRequest = S.struct({
    name = "ProjectCreateRequest",
    members = {
      m({ name = "name", schema = S.string }),
      m({ name = "region_id", schema = S.string }),
      m({ name = "settings", schema = S.ref("ProjectSettings") }),
    },
  })
  shapes.ApiKeyCreateResponse = S.struct({
    name = "ApiKeyCreateResponse",
    members = {
      m({ name = "id", schema = S.number, required = true }),
      m({ name = "key", schema = S.string, required = true, sensitive = true }),
      m({ name = "name", schema = S.string, required = true }),
    },
  })
  shapes.Branch = S.struct({
    name = "Branch",
    members = {
      m({ name = "id", schema = S.string, required = true }),
      m({ name = "display_name", wire = "name", schema = S.string }),
      m({ name = "protected", schema = S.boolean }),
    },
  })
  return shapes
end

function fixtures.errors()
  return {
    BadRequest = errors.define({
      tag = "BadRequest",
      categories = { "BadRequestError" },
      matchers = { { status = 400 } },
    }),
    NotFound = errors.define({
      tag = "NotFound",
      categories = { "NotFoundError" },
      matchers = { { status = 404 } },
    }),
    -- a patch-style matcher: status plus a JavaScript regex on the message
    ProjectLocked = errors.define({
      tag = "ProjectLocked",
      categories = { "LockedError" },
      retryable = true,
      matchers = { { status = 423, message = { matches = "^project [^ ]+ is locked( by .+)?$" } } },
      fields = { "code", "request_id", "retry_after" },
    }),
    Locked = errors.define({
      tag = "Locked",
      categories = { "LockedError" },
      matchers = { { status = 423 } },
    }),
  }
end

function fixtures.ops()
  local ops = {}
  ops.get_project = {
    name = "GetProject",
    method = "GET",
    uri = "/projects/{project_id}",
    code = 200,
    input = S.struct({
      name = "GetProjectRequest",
      members = {
        m({ name = "project_id", bind = "label", schema = S.string, required = true }),
      },
    }),
    output = S.ref("ProjectResponse"),
    errors = { "BadRequest", "NotFound" },
    span = "Neon.GetProject",
  }
  ops.list_projects = {
    name = "ListProjects",
    method = "GET",
    uri = "/projects",
    code = 200,
    input = S.struct({
      name = "ListProjectsRequest",
      members = {
        m({ name = "cursor", bind = "query", schema = S.string }),
        m({ name = "limit", bind = "query", schema = S.number }),
        m({ name = "search", bind = "query", schema = S.string }),
        m({ name = "org_id", bind = "query", schema = S.string }),
      },
    }),
    output = S.ref("ListProjectsResponse"),
    errors = { "BadRequest" },
    pagination = {
      mode = "cursor",
      input_token = "cursor",
      output_token = "pagination.cursor",
      items = "projects",
      page_size = "limit",
    },
    span = "Neon.ListProjects",
  }
  ops.create_project = {
    name = "CreateProject",
    method = "POST",
    uri = "/projects",
    code = 201,
    input = S.struct({
      name = "CreateProjectRequest",
      members = {
        m({ name = "project", schema = S.ref("ProjectCreateRequest"), required = true }),
      },
    }),
    output = S.ref("ProjectResponse"),
    errors = { "BadRequest", "ProjectLocked", "Locked" },
    span = "Neon.CreateProject",
  }
  ops.update_branch = {
    name = "UpdateProjectBranch",
    method = "PATCH",
    uri = "/projects/{project_id}/branches/{branch_id}",
    code = 200,
    input = S.struct({
      name = "UpdateProjectBranchRequest",
      members = {
        m({ name = "project_id", bind = "label", schema = S.string, required = true }),
        m({ name = "branch_id", bind = "label", schema = S.string, required = true }),
        m({ name = "request_id", wire = "X-Request-Id", bind = "header", schema = S.string }),
        m({ name = "display_name", wire = "name", schema = S.string }),
        m({ name = "protected", schema = S.boolean, string_encoded = true }),
      },
    }),
    output = S.ref("Branch"),
    errors = { "BadRequest", "NotFound" },
  }
  ops.create_api_key = {
    name = "CreateApiKey",
    method = "POST",
    uri = "/api_keys",
    code = 200,
    input = S.struct({
      name = "CreateApiKeyRequest",
      members = { m({ name = "key_name", schema = S.string, required = true }) },
    }),
    output = S.ref("ApiKeyCreateResponse"),
    errors = {},
  }
  ops.get_bucket_object = {
    name = "GetProjectBranchBucketObject",
    method = "GET",
    uri = "/projects/{project_id}/objects/{key+}",
    code = 200,
    input = S.struct({
      name = "GetProjectBranchBucketObjectRequest",
      members = {
        m({ name = "project_id", bind = "label", schema = S.string, required = true }),
        m({ name = "key", bind = "label", schema = S.string, required = true, greedy = true }),
      },
    }),
    output = S.blob,
    output_raw = true,
    errors = { "NotFound" },
  }
  return ops
end

--- fixtures.service() -> a fresh service descriptor (docs/interfaces.md)
function fixtures.service()
  return {
    name = "neon",
    shapes = fixtures.shapes(),
    errors = fixtures.errors(),
    ops = fixtures.ops(),
    telemetry = { system = "neon-api" },
  }
end

fixtures.BASE_URL = "https://console.neon.tech/api/v2"

-- Canned wire bodies (Lua tables; testing.transport encodes them).
fixtures.bodies = {}

function fixtures.bodies.project(id, name)
  return {
    project = {
      id = id or "p1",
      name = name or "demo",
      region_id = "aws-us-east-2",
      created_at = "2024-01-01T00:00:00Z",
      pg_version = 17,
      effective_project_permission = json.null,
      settings = { allowed_ips = json.array({}), quota = {} },
    },
  }
end

--- fixtures.bodies.page(ids, cursor): a list_projects page; no cursor ends the listing
function fixtures.bodies.page(ids, cursor)
  local projects = json.array({})
  for i, id in ipairs(ids) do
    projects[i] = fixtures.bodies.project(id).project
  end
  local body = { projects = projects }
  if cursor ~= nil then
    body.pagination = { cursor = cursor }
  end
  return body
end

function fixtures.bodies.api_key(key)
  return { id = 42, key = key or "napi_FIXTURE-SECRET", name = "ci" }
end

function fixtures.bodies.error(message, code)
  return { message = message, code = code }
end

return fixtures
