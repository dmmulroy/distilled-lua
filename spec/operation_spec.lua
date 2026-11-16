-- The operation layer: span facts (telemetry.ts operationInfo, readRules, transforms),
-- one span per call, flush on the outermost return, trace ids on errors, tracing off.
local t = require("spec.harness")
local operation = require("distilled.operation")
local Client = require("distilled.client")
local rest = require("distilled.protocol.rest")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")
local trace = require("distilled.trace")
local expect = require("distilled.testing.expect")

local function must(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

local NEON_TELEMETRY = { system = "neon-api", prefix = "Neon", service = "Neon", labels = "neon" }

local function neon_service()
  local service = fixtures.service()
  service.telemetry = NEON_TELEMETRY
  for _, op in pairs(service.ops) do
    op.span = op.name
  end
  return service
end

t.describe("operation.info (telemetry.ts operationInfo)", function()
  local service = neon_service()

  t.it(
    "a span naming its op derives name, rpc.method, url.template and label attributes",
    function()
      local info = operation.info(service, service.ops.update_branch)
      t.eq(info.name, "Neon.UpdateProjectBranch")
      t.eq(info.kind, "client")
      t.same(info.attributes, {
        ["rpc.system.name"] = "neon-api",
        ["rpc.method"] = "Neon/UpdateProjectBranch",
        ["url.template"] = "/projects/{project_id}/branches/{branch_id}",
      })
      t.same(info.input, {
        { "branch_id", { name = "neon.branch_id" } },
        { "project_id", { name = "neon.project_id" } },
      })
    end
  )

  t.it("the query part of the uri is not in url.template", function()
    local op = { name = "X", method = "GET", uri = "/x/{id}?fixed=1", span = "X" }
    t.eq(operation.info(service, op).attributes["url.template"], "/x/{id}")
  end)

  t.it("label_names and span.input replace derived rules; [] records nothing", function()
    local svc =
      { telemetry = { system = "s", labels = "svc", label_names = { project_id = "svc.project" } } }
    local op = {
      name = "Op",
      uri = "/p/{project_id}/{zoneId}",
      input = S.struct({
        name = "I",
        members = {
          S.member({ name = "project_id", bind = "label", schema = S.string }),
          S.member({ name = "zoneId", bind = "label", schema = S.string }),
        },
      }),
      span = { op = "Op", input = { zoneId = {} } },
    }
    local info = operation.info(svc, op)
    t.same(info.input, { { "project_id", { name = "svc.project" } } })
    t.eq(info.name, "Op")
  end)

  t.it("snake_case spells labels as Distilled does", function()
    t.eq(operation._snake_case("zoneId"), "zone_id")
    t.eq(operation._snake_case("zone-id"), "zone_id")
    t.eq(operation._snake_case("ZoneID"), "zone_id")
    t.eq(operation._snake_case("HTTPServerName"), "http_server_name")
  end)

  t.it("templates = false or span.template = false drop url.template", function()
    local op = { name = "X", uri = "/x", span = "X" }
    t.eq(
      operation.info({ telemetry = { system = "s", templates = false } }, op).attributes["url.template"],
      nil
    )
    local op2 = { name = "X", uri = "/x", span = { op = "X", template = false } }
    t.eq(operation.info({ telemetry = { system = "s" } }, op2).attributes["url.template"], nil)
  end)

  t.it("fixed attributes: service, then span; json.null drops one the service sets", function()
    local svc = { telemetry = { system = "s", attributes = { a = 1, b = 2 } } }
    local op =
      { name = "X", uri = "/x", span = { op = "X", attributes = { b = json.null, c = 3 } } }
    local attrs = operation.info(svc, op).attributes
    t.eq(attrs.a, 1)
    t.eq(attrs.b, nil)
    t.eq(attrs.c, 3)
  end)

  t.it(
    "explicit name, method and kind win; no span falls back to op.name, then distilled.operation",
    function()
      local op = {
        name = "X",
        uri = "/x",
        span = { op = "X", name = "Custom", method = "M/x", kind = "producer" },
      }
      local info = operation.info(service, op)
      t.eq(info.name, "Custom")
      t.eq(info.attributes["rpc.method"], "M/x")
      t.eq(info.kind, "producer")
      t.eq(operation.info(service, { name = "Plain", uri = "/p" }).name, "Plain")
      t.eq(operation.info({}, { uri = "/p" }).name, "distilled.operation")
      -- without span.op nothing is derived
      t.eq(operation.info(service, { name = "Plain", uri = "/p" }).attributes["url.template"], nil)
    end
  )
end)

t.describe("operation: attribute transforms", function()
  local tr = operation._transform
  t.it(
    "plain values: scalars and non-empty scalar lists; secrets and tables are skipped",
    function()
      t.eq(tr({ name = "x" }, "v"), "v")
      t.eq(tr({ name = "x" }, 3), 3)
      t.same(tr({ name = "x" }, json.array({ "a", "b" })), { "a", "b" })
      t.eq(tr({ name = "x" }, json.array({})), nil)
      t.eq(tr({ name = "x" }, { a = 1 }), nil)
      t.eq(tr({ name = "x" }, secret.wrap("s")), nil)
      t.eq(tr({ name = "x" }, json.null), nil)
      t.eq(tr({ name = "x", field = "a.b" }, { a = { b = "deep" } }), "deep")
      t.eq(tr({ name = "x", field = "a.b" }, { a = secret.wrap("s") }), nil)
    end
  )

  t.it("the named transforms", function()
    t.eq(tr({ transform = "nonZero" }, 0), nil)
    t.eq(tr({ transform = "nonZero" }, 5), 5)
    t.same(tr({ transform = "list" }, "a"), { "a" })
    t.same(tr({ transform = "keys" }, { b = 1, a = 2 }), { "a", "b" })
    t.eq(tr({ transform = "count" }, json.array({ 1, 2, 3 })), 3)
    t.eq(tr({ transform = "count" }, json.array({})), 0)
    t.eq(tr({ transform = "lastPathSegment" }, "a/b/c"), "c")
    t.eq(tr({ transform = "arnResource" }, "arn:aws:s3:::bucket"), "bucket")
    t.eq(tr({ transform = "arn" }, "arn:aws:x"), "arn:aws:x")
    t.eq(tr({ transform = "arn" }, "nope"), nil)
    t.same(tr({ transform = "jsonList" }, json.array({ { a = 1 }, 2 })), { '{"a":1}', "2" })
    t.same(tr({ transform = "jsonList" }, { a = 1 }), { '{"a":1}' })
  end)
end)

local function client_for(service, responses, tracer_opts)
  local Neon = Client.define({
    service = service,
    protocol = rest.new({ base_url = fixtures.BASE_URL, headers = rest.bearer("api_key") }),
    options = { api_key = { secret = true } },
  })
  local host = testing.host({ responses = responses })
  local memory = trace.exporters.memory()
  local opts = { host = host, api_key = "k", retry = "none" }
  if tracer_opts ~= false then
    opts.tracer = trace.new({
      level = (tracer_opts or {}).level or "operation",
      exporter = memory,
      host = host,
    })
  end
  return Neon.new(opts), host, memory
end

t.describe("operation: the span of a call", function()
  t.it("one client span per call with input, output and response header rules", function()
    local service = neon_service()
    service.telemetry = {
      system = "neon-api",
      prefix = "Neon",
      service = "Neon",
      labels = "neon",
      response_headers = { { header = "X-Neon-Request-Id", name = "neon.request_id" } },
    }
    service.ops.get_project.span = {
      op = "GetProject",
      output = { project = { { name = "neon.region", field = "region_id" } } },
    }
    local c, _, memory = client_for(service, {
      { body = fixtures.bodies.project("p1"), headers = { ["x-neon-request-id"] = "req-1" } },
    })
    must(c:get_project({ project_id = "p1" }))
    t.eq(#memory.spans, 1)
    local s = expect(memory.spans):span("Neon.GetProject")
    s:ok()
      :attr("neon.project_id", "p1")
      :attr("neon.region", "aws-us-east-2")
      :attr("neon.request_id", "req-1")
      :attr("rpc.method", "Neon/GetProject")
      :attr("url.template", "/projects/{project_id}")
    t.eq(memory.spans[1].kind, "client")
  end)

  t.it("a secret input value is never recorded", function()
    local CANARY = "p-CANARY-op"
    local c, _, memory = client_for(neon_service(), { { body = fixtures.bodies.project("p1") } })
    must(c:get_project({ project_id = secret.wrap(CANARY) }))
    expect(memory.spans):span("Neon.GetProject"):no_attr("neon.project_id")
    expect(memory.spans):no_attr_contains(CANARY)
  end)

  t.it("a failed call: error.type, status error, and err.trace_id", function()
    local c, _, memory =
      client_for(neon_service(), { { status = 404, body = { message = "missing" } } })
    local _, err = c:get_project({ project_id = "p1" })
    expect(memory.spans)
      :span("Neon.GetProject")
      :failed("NotFound")
      :attr("http.response.status_code", 404)
    t.eq(err.trace_id, memory.spans[1].trace_id)
  end)

  t.it("with tracing off the error has no trace id", function()
    local c = client_for(neon_service(), { { status = 404, body = {} } }, false)
    local _, err = c:get_project({ project_id = "p1" })
    t.eq(err.trace_id, nil)
    t.no_match(tostring(err), "trace", true)
  end)

  t.it("the input is never mutated", function()
    local c = client_for(neon_service(), { { body = fixtures.bodies.page({ "a" }) } })
    local input = { limit = 5, search = "x" }
    must(c:list_projects(input))
    t.same(input, { limit = 5, search = "x" })
  end)

  t.it(
    "debug level: attempt, credentials, build, transport and decode spans under the call",
    function()
      local c, _, memory = client_for(
        neon_service(),
        { { body = fixtures.bodies.project("p1") } },
        { level = "debug" }
      )
      must(c:get_project({ project_id = "p1" }))
      local e = expect(memory.spans)
      local attempt = e:span("Neon.GetProject"):children("distilled.attempt"):count(1)
      attempt:attr("distilled.attempt", 1):attr("http.request.resend_count", 0)
      for _, name in ipairs({
        "distilled.credentials",
        "distilled.request.build",
        "distilled.transport",
        "distilled.decode",
      }) do
        attempt:children(name):count(1)
      end
      e:span("distilled.transport"):attr("http.response.status_code", 200)
    end
  )
end)

t.describe("operation: flushing", function()
  local function counting_exporter()
    local ex = { flushes = 0, spans = {} }
    return setmetatable(ex, {
      __call = function(self, spans)
        self.flushes = self.flushes + 1
        for _, s in ipairs(spans) do
          self.spans[#self.spans + 1] = s
        end
        return true
      end,
    })
  end

  t.it("spans are exported when the call returns", function()
    local ex = counting_exporter()
    local host = testing.host({
      responses = {
        { body = fixtures.bodies.project("p1") },
        { body = fixtures.bodies.project("p2") },
      },
    })
    local Neon = Client.define({
      service = neon_service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local c = Neon.new({ host = host, tracing = { level = "operation", exporter = ex } })
    must(c:get_project({ project_id = "p1" }))
    t.eq(ex.flushes, 1)
    t.eq(#ex.spans, 1)
    must(c:get_project({ project_id = "p2" }))
    t.eq(ex.flushes, 2)
    t.eq(#ex.spans, 2)
  end)

  t.it(
    "a call made inside another call on the same tracer is flushed with the outer one",
    function()
      local ex = counting_exporter()
      local Neon = Client.define({
        service = neon_service(),
        protocol = rest.new({ base_url = fixtures.BASE_URL }),
      })
      local holder = {}
      local host = testing.host({
        responses = {
          function()
            -- e.g. a transport that looks something up through the same client
            must(holder.client:get_project({ project_id = "inner" }))
            t.eq(ex.flushes, 0)
            return { body = fixtures.bodies.project("outer") }
          end,
          { body = fixtures.bodies.project("inner") },
        },
      })
      holder.client = Neon.new({ host = host, tracing = { level = "operation", exporter = ex } })
      must(holder.client:get_project({ project_id = "outer" }))
      t.eq(ex.flushes, 1)
      t.eq(#ex.spans, 2)
      local e = expect(ex.spans)
      t.eq(#e:spans("Neon.GetProject"):list(), 2)
    end
  )

  t.it("a raise inside the call ends the span, flushes, and propagates", function()
    local ex = counting_exporter()
    local Neon = Client.define({
      service = neon_service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local host = testing.host({ responses = { { body = fixtures.bodies.project("p2") } } })
    local c = Neon.new({ host = host, tracing = { level = "operation", exporter = ex } })
    -- the first request raises (a transport bug)
    host.transport.responses = {
      function()
        error("transport bug")
      end,
      { body = fixtures.bodies.project("p2") },
    }
    t.raises(function()
      c:get_project({ project_id = "p1" })
    end, "transport bug")
    t.eq(ex.flushes, 1)
    expect(ex.spans):span("Neon.GetProject"):failed()
    -- depth was restored: the next call flushes on its own
    must(c:get_project({ project_id = "p2" }))
    t.eq(ex.flushes, 2)
  end)

  t.it("an exporter that fails does not fail the call; close reports it", function()
    local Neon = Client.define({
      service = neon_service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local host = testing.host({ responses = { { body = fixtures.bodies.project("p1") } } })
    local tracer = trace.new({
      level = "operation",
      host = host,
      exporter = function()
        return nil, "disk full"
      end,
    })
    local c = Neon.new({ host = host, tracer = tracer })
    must(c:get_project({ project_id = "p1" }))
    -- nothing buffered now: close succeeds
    t.eq(c:close(), true)
    tracer:start("left open"):finish()
    local ok, err = c:close()
    t.eq(ok, nil)
    t.match(err.message, "disk full", true)
  end)
end)

t.describe("operation: tracing off never loads the tracer", function()
  t.it("a client with tracing off does not require distilled.trace", function()
    local saved = {}
    for name in pairs(package.loaded) do
      if
        name == "distilled.trace"
        or string.find(name, "^distilled%.trace%.") and name ~= "distilled.trace.noop"
      then
        saved[name] = package.loaded[name]
        package.loaded[name] = nil
      end
    end
    local Neon = Client.define({
      service = neon_service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local host =
      testing.host({ responses = { { body = fixtures.bodies.project("p1") }, { status = 503 } } })
    local c = Neon.new({ host = host, tracing = "off", retry = "none" })
    must(c:get_project({ project_id = "p1" }))
    c:get_project({ project_id = "p1" })
    must(c:with({}):close())
    local loaded = package.loaded["distilled.trace"]
    for name, m in pairs(saved) do
      package.loaded[name] = m
    end
    t.eq(loaded, nil)
  end)
end)
