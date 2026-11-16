-- A runnable tour of the runtime over the scripted transport: a Neon-shaped client calls
-- a retried operation, a paginated one and a failing one, traced.
--
--   verify/dl trace  examples/fake_service.lua --level debug [--runtime lua|luajit|rex]
--   verify/dl expect examples/fake_service.lua
--
-- The service is the fixture from distilled.testing.fixtures with Neon's telemetry rules;
-- the host is the `dl` environment's virtual clock (backoff sleeps advance it at once)
-- plus a scripted transport, so nothing touches the network.
-- Returns the expect check (used by `dl expect`) and the results.
local env = require("verify.lib.trace_env")
local Client = require("distilled.client")
local rest = require("distilled.protocol.rest")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")

local CANARY = "napi_CANARY-fake-service"

-- the service: fixture ops, named and attributed as the Neon model's telemetry traits do
local service = fixtures.service()
service.telemetry = { system = "neon-api", prefix = "Neon", service = "Neon", labels = "neon" }
for _, op in pairs(service.ops) do
  op.span = op.name
end

local Neon = Client.define({
  service = service,
  protocol = rest.new({
    base_url = function(creds)
      return creds.base_url
    end,
    headers = rest.bearer("api_key"),
    unknown_tag = "UnknownNeonError",
    parse_tag = "NeonParseError",
  }),
  options = {
    api_key = { secret = true, env = "NEON_API_KEY", required = true },
    base_url = { default = fixtures.BASE_URL },
  },
})

local transport = testing.transport({
  responses = {
    -- get_project: throttled, then a server error, then the project
    { status = 429, headers = { ["retry-after"] = "1" }, body = { message = "slow down" } },
    { status = 503, body = { message = "try again" } },
    { status = 200, body = fixtures.bodies.project("proj-quiet-sun", "quiet-sun") },
    -- list_projects_items: two pages
    { status = 200, body = fixtures.bodies.page({ "proj-a", "proj-b" }, "cursor-2") },
    { status = 200, body = fixtures.bodies.page({ "proj-c" }) },
    -- get_project: not found
    { status = 404, body = { message = "project not found", code = "NOT_FOUND" } },
  },
})

local host = {}
for k, v in pairs(env.host) do
  host[k] = v
end
host.transport = transport

local neon = Neon.new({ host = host, api_key = CANARY, tracer = env.tracer })

local results = {}

local project, err = neon:get_project({ project_id = "proj-quiet-sun" })
results.get_project = project and project.project.name or tostring(err)

local items, list_err = neon:list_projects_items({ limit = 2 }):collect()
if items then
  local ids = {}
  for i, p in ipairs(items) do
    ids[i] = p.id
  end
  results.list_projects = table.concat(ids, ",")
else
  results.list_projects = tostring(list_err)
end

local missing, missing_err = neon:get_project({ project_id = "proj-missing" })
results.missing = missing and "found?" or tostring(missing_err)
results.requests = #transport.requests

neon:close()

print("results: get_project=" .. results.get_project)
print("results: list_projects=" .. results.list_projects)
print("results: missing=" .. results.missing)
print("results: requests=" .. results.requests)

local function check(e)
  if results.get_project ~= "quiet-sun" or results.list_projects ~= "proj-a,proj-b,proj-c" then
    error("unexpected results")
  end
  local calls = e:spans("Neon.GetProject"):count(2)
  calls
    :nth(1)
    :ok()
    :attr("distilled.attempts", 3)
    :attr("distilled.retry.errors", { "TooManyRequests", "ServiceUnavailable" })
  calls:nth(2):failed("NotFound"):attr("http.response.status_code", 404)
  e:span("distilled.pagination")
    :attr("distilled.pagination.pages", 2)
    :children("Neon.ListProjects")
    :count(2)
  e:no_attr_contains(CANARY)
  if env.tracer.level == "debug" then
    e:spans("distilled.retry.backoff"):count(2)
    -- Retry-After: 1 is the least the first backoff waits
    e:spans("distilled.retry.backoff"):nth(1):attr("distilled.retry.delay_ms", 1000)
  end
end

return check, results
