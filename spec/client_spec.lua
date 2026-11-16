-- Client.define / new / with / close, method dispatch, option checking, tracing options
-- and the host table.
local t = require("spec.harness")
local Client = require("distilled.client")
local hostlib = require("distilled.host")
local rest = require("distilled.protocol.rest")
local retry = require("distilled.retry")
local distilled = require("distilled")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")
local trace = require("distilled.trace")
local noop = require("distilled.trace.noop")
local expect = require("distilled.testing.expect")
local otlp = require("distilled.trace.otlp")

local function must(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

local function neon_service()
  local service = fixtures.service()
  service.telemetry = { system = "neon-api", prefix = "Neon", service = "Neon", labels = "neon" }
  for _, op in pairs(service.ops) do
    op.span = op.name
  end
  return service
end

local Neon = Client.define({
  service = neon_service(),
  protocol = rest.new({
    base_url = function(c)
      return c.base_url
    end,
    headers = rest.bearer("api_key"),
  }),
  options = {
    api_key = { secret = true, env = "NEON_API_KEY", required = true },
    base_url = { default = fixtures.BASE_URL, type = "string" },
  },
})

local function project()
  return { body = fixtures.bodies.project("p1") }
end

t.describe("Client.define", function()
  t.it("names methods after service.ops, with _pages and _items for paginated ones", function()
    local c = Neon.new({ api_key = "k" })
    for _, name in ipairs({
      "get_project",
      "list_projects",
      "list_projects_pages",
      "list_projects_items",
      "create_project",
      "update_branch",
      "create_api_key",
      "get_bucket_object",
      "with",
      "close",
    }) do
      t.eq(type(c[name]), "function", name)
    end
    t.eq(c.get_project_pages, nil)
    t.eq(c.nonexistent, nil)
    t.truthy(Neon.is(c))
    t.falsy(Neon.is({}))
    t.eq(tostring(c), "neon client")
  end)

  t.it("refuses names that collide, common option names and malformed specs", function()
    local service = fixtures.service()
    service.ops.list_projects_pages = service.ops.get_project
    t.raises(function()
      Client.define({ service = service, protocol = rest.new({ base_url = "x" }) })
    end, "collides")
    local s2 = fixtures.service()
    s2.ops.with = s2.ops.get_project
    t.raises(function()
      Client.define({ service = s2, protocol = rest.new({ base_url = "x" }) })
    end, "collides")
    t.raises(function()
      Client.define({
        service = fixtures.service(),
        protocol = rest.new({ base_url = "x" }),
        options = { retry = {} },
      })
    end, "common client option")
    t.raises(function()
      Client.define({
        service = fixtures.service(),
        protocol = rest.new({ base_url = "x" }),
        options = { k = { secrets = true } },
      })
    end, "unknown field secrets")
    t.raises(function()
      Client.define({ service = {}, protocol = rest.new({ base_url = "x" }) })
    end, "service descriptor")
    t.raises(function()
      Client.define({ service = fixtures.service(), protocol = {} })
    end, "protocol")
  end)
end)

-- task 09: the transport modules are constructors; passing one is misuse, caught in new
t.describe("Class.new: a transport module instead of a transport", function()
  t.it("transport = the popen_curl or exec_curl module raises and says what to pass", function()
    local popen_curl = require("distilled.transport.popen_curl")
    local exec_curl = require("distilled.transport.exec_curl")
    for _, case in ipairs({
      { { transport = popen_curl }, "distilled.transport.popen_curl" },
      { { host = { transport = popen_curl } }, "distilled.transport.popen_curl" },
      { { transport = exec_curl }, "distilled.transport.exec_curl" },
    }) do
      local opts = case[1]
      opts.api_key = "k"
      local raised = t.raises(function()
        Neon.new(opts)
      end, "transport is the " .. case[2] .. " module")
      raised = tostring(raised)
      t.match(raised, 'require("distilled.transport.popen_curl")()', true)
      t.match(raised, 'require("distilled.transport.exec_curl")(exec)', true)
      t.match(raised, 'host = require("distilled.host.popen")()', true)
    end
  end)

  t.it("host = the host.popen module (a function) says to call it", function()
    local raised = t.raises(function()
      Neon.new({ host = function() end })
    end, "host must be a table")
    t.match(tostring(raised), 'require("distilled.host.popen")()', true)
  end)
end)

t.describe("Class.new: options", function()
  t.it("an unknown option is misuse, and the message lists the valid names", function()
    local raised = t.raises(function()
      Neon.new({ apikey = "x" })
    end, "unknown option apikey")
    t.match(tostring(raised), "valid: api_key, base_url, budget, deadline_s", true)
  end)

  t.it("option types are checked", function()
    local cases = {
      { { host = 1 }, "host must be a table" },
      { { transport = "curl" }, "transport must be a function" },
      { { host = { sleep = 3 } }, "host.sleep must be a function" },
      { { retry = 5 }, "retry option" },
      { { deadline_s = -1 }, "deadline_s" },
      { { tracing = "verbose" }, "tracing" },
      { { tracing = { level = "loud" } }, "tracing.level" },
      { { tracing = { path = "x" } }, "unknown tracing field path" },
      { { tracer = {} }, "tracer must be a tracer" },
      { { validation = "exact" }, "validation" },
      { { budget = {} }, "budget" },
      { { base_url = 3 }, "base_url must be a string" },
      { { trace_parent = 1 }, "trace_parent" },
      { { user_agent = 1 }, "user_agent" },
    }
    for _, case in ipairs(cases) do
      t.raises(function()
        Neon.new(case[1])
      end, case[2])
    end
    t.raises(function()
      Neon.new("x")
    end, "expected a table")
  end)

  t.it("calling with . instead of : is a clear misuse message", function()
    local c = Neon.new({ api_key = "k" })
    t.raises(function()
      c.get_project({ project_id = "p1" })
    end, "call client:get_project%(...%) with a colon")
    t.raises(function()
      c.list_projects_items({})
    end, "client:list_projects_items")
    t.raises(function()
      c.with({})
    end, "client:with")
  end)

  t.it("new copies its options: changing the table later has no effect", function()
    local host = testing.host({ responses = { project() } })
    local opts = { host = host, api_key = "k1" }
    local c = Neon.new(opts)
    opts.api_key = "k2"
    must(c:get_project({ project_id = "p1" }))
    t.eq(host.requests[1].headers.authorization, "Bearer k1")
  end)

  t.it("top-level host fields win over host = {...}", function()
    local host = testing.host({ responses = {} })
    local tr = testing.transport({ responses = { project() } })
    local c = Neon.new({ host = host, transport = tr, api_key = "k" })
    must(c:get_project({ project_id = "p1" }))
    t.eq(#tr.requests, 1)
    t.eq(#host.requests, 0)
  end)
end)

t.describe("client:with", function()
  t.it("derives a client with a shallow override; the parent is unchanged", function()
    local host = testing.host({ responses = { project(), project() } })
    local c = Neon.new({ host = host, api_key = "k", base_url = "https://a.test" })
    local d = c:with({ base_url = "https://b.test" })
    must(d:get_project({ project_id = "p1" }))
    must(c:get_project({ project_id = "p1" }))
    t.match(host.requests[1].url, "^https://b.test/")
    t.match(host.requests[2].url, "^https://a.test/")
  end)

  t.it(
    "shares the tracer unless tracing is overridden; tracing = off silences a derived client",
    function()
      local host = testing.host({ responses = { project(), project(), project() } })
      local memory = trace.exporters.memory()
      local c = Neon.new({
        host = host,
        api_key = "k",
        tracing = { level = "operation", exporter = memory },
      })
      must(c:with({ validation = "strict" }):get_project({ project_id = "p1" }))
      t.eq(#memory.spans, 1)
      must(c:with({ tracing = "off" }):get_project({ project_id = "p1" }))
      t.eq(#memory.spans, 1)
      must(c:get_project({ project_id = "p1" }))
      t.eq(#memory.spans, 2)
    end
  )

  t.it("shares the budget unless budget is overridden", function()
    local budget = retry.new_budget({ initial = 14 })
    local host = testing.host({
      responses = { { status = 503 }, { status = 503 }, { status = 503 }, { status = 503 } },
    })
    host.random = function()
      return 0
    end
    local c = Neon.new({ host = host, api_key = "k", budget = budget })
    t.fails_with("ServiceUnavailable", c:with({}):get_project({ project_id = "p1" }))
    -- one retry paid with the shared 14 tokens
    t.eq(#host.requests, 2)
    t.eq(budget:tokens("console.neon.tech"), 0)
    t.fails_with("ServiceUnavailable", c:get_project({ project_id = "p1" }))
    t.eq(#host.requests, 3)
  end)

  t.it("checks its overrides like new", function()
    local c = Neon.new({ api_key = "k" })
    t.raises(function()
      c:with({ nope = 1 })
    end, "unknown option nope")
  end)
end)

t.describe("client: tracing options", function()
  t.it('"off" (the default) holds the no-op tracer', function()
    local c = Neon.new({ api_key = "k" })
    t.eq(c._state.trace.tracer, noop)
    t.eq(Neon.new({ api_key = "k", tracing = "off" })._state.trace.tracer, noop)
  end)

  t.it("a string level without an exporter writes the console tree to stderr", function()
    local c = Neon.new({ api_key = "k", tracing = "debug" })
    local tracer = c._state.trace.tracer
    t.eq(tracer.level, "debug")
    t.eq(tracer.service_name, "neon")
  end)

  t.it("{ file, max_bytes } writes OTLP/JSON lines", function()
    local path = t.root .. "/verify/tmp/client_spec_trace.jsonl"
    os.remove(path)
    local host = testing.host({ responses = { project() } })
    local c = Neon.new({
      host = host,
      api_key = "k",
      tracing = { level = "operation", file = path, max_bytes = 100000 },
    })
    must(c:get_project({ project_id = "p1" }))
    local f = io.open(path, "rb")
    if not f then
      t.pending("verify/tmp is not writable")
      return
    end
    local text = f:read("*a")
    f:close()
    os.remove(path)
    local spans = must(otlp.decode_lines(text))
    t.eq(#spans, 1)
    t.eq(spans[1].name, "Neon.GetProject")
  end)

  t.it("trace_parent, or TRACEPARENT from host.getenv, continues the caller's trace", function()
    local parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    for _, opts in ipairs({ { trace_parent = parent }, { env = { TRACEPARENT = parent } } }) do
      local host = testing.host({ responses = { project() }, env = opts.env })
      local memory = trace.exporters.memory()
      local c = Neon.new({
        host = host,
        api_key = "k",
        trace_parent = opts.trace_parent,
        tracing = { level = "operation", exporter = memory },
      })
      must(c:get_project({ project_id = "p1" }))
      t.eq(memory.spans[1].trace_id, "4bf92f3577b34da6a3ce929d0e0e4736")
      t.eq(memory.spans[1].parent_span_id, "00f067aa0ba902b7")
      t.match(host.requests[1].headers.traceparent, "^00%-4bf92f3577b34da6a3ce929d0e0e4736%-")
    end
  end)

  t.it("close flushes and returns true", function()
    local memory = trace.exporters.memory()
    local c = Neon.new({ api_key = "k", tracing = { exporter = memory } })
    t.eq(c._state.trace.tracer.level, "operation")
    c._state.trace.tracer:start("pending"):finish()
    t.eq(#memory.spans, 0)
    t.eq(c:close(), true)
    t.eq(#memory.spans, 1)
  end)
end)

t.describe("client: end to end over the scripted transport", function()
  t.it("a retried, a paginated and a failing call, traced", function()
    local host = testing.host({
      seed = 5,
      responses = {
        { status = 429 },
        project(),
        { body = fixtures.bodies.page({ "a", "b" }, "c1") },
        { body = fixtures.bodies.page({ "c" }) },
        { status = 404, body = { message = "no such project" } },
      },
    })
    local memory = trace.exporters.memory()
    local c =
      Neon.new({ host = host, api_key = "k", tracing = { level = "debug", exporter = memory } })
    must(c:get_project({ project_id = "p1" }))
    t.eq(#must(c:list_projects_items({}):collect()), 3)
    local _, err = c:get_project({ project_id = "missing" })
    t.eq(err.tag, "NotFound")
    t.truthy(err.trace_id)
    local e = expect(memory.spans)
    e:spans("Neon.GetProject"):count(2)
    e:spans("Neon.GetProject"):nth(1):ok():attr("distilled.attempts", 2)
    e:spans("Neon.GetProject"):nth(2):failed("NotFound")
    e:span("distilled.pagination"):children("Neon.ListProjects"):count(2)
    e:spans("distilled.retry.backoff"):count(1)
  end)
end)

t.describe("host", function()
  t.it(
    "merge: base fields, top-level fields win, defaults fill the rest; inputs unchanged",
    function()
      local base = {
        now = function()
          return 1
        end,
        extra = "kept",
      }
      local top = {
        now = function()
          return 2
        end,
        api_key = "ignored",
      }
      local h = hostlib.merge(base, top)
      t.eq(h.now(), 2)
      t.eq(h.extra, "kept")
      t.eq(h.api_key, nil)
      t.eq(h.transport, nil)
      t.eq(type(h.sleep), "function")
      t.eq(h.epoch, os.time)
      t.eq(h.getenv, os.getenv)
      t.eq(base.sleep, nil)
    end
  )

  t.it("the default random is in [0, 1) and differs between hosts", function()
    local a, b = hostlib.default().random, hostlib.default().random
    local same = true
    for _ = 1, 20 do
      local x, y = a(), b()
      t.truthy(x >= 0 and x < 1)
      if x ~= y then
        same = false
      end
    end
    t.falsy(same)
  end)

  t.it("the default sleep waits (busy) and ignores bad values", function()
    local start = os.clock()
    hostlib._busy_sleep(0.01)
    t.truthy(os.clock() - start >= 0.009)
    hostlib._busy_sleep(-1)
    hostlib._busy_sleep(0 / 0)
  end)
end)

t.describe("distilled exports", function()
  t.it("the runtime modules are reachable from require('distilled')", function()
    t.eq(distilled.Client, Client)
    t.eq(distilled.rest, rest)
    t.eq(distilled.retry, retry)
    t.eq(distilled.paginate, require("distilled.paginate"))
    t.eq(distilled.credentials, require("distilled.credentials"))
    t.eq(distilled.host, hostlib)
    t.eq(distilled.nothing, nil)
  end)
end)

---------------------------------------------------------------------------------------
-- golden traces of real calls (ids and times normalised by tree.golden)
-- regenerate: DL_GOLDEN_WRITE=1 lua spec/run.lua client_spec
---------------------------------------------------------------------------------------

local tree = require("distilled.trace.tree")

local function golden_run(level, responses, fn)
  local host = testing.host({ responses = responses, seed = 11, epoch = 1700000000 })
  local memory = trace.exporters.memory()
  local c =
    Neon.new({ host = host, api_key = "sk-golden", tracing = { level = level, exporter = memory } })
  fn(c)
  c:close()
  return tree.golden(memory.spans)
end

local GOLDEN = {
  {
    file = "runtime_get_project_retry.txt",
    render = function()
      return golden_run("debug", { { status = 429 }, { status = 503 }, project() }, function(c)
        must(c:get_project({ project_id = "p1" }))
      end)
    end,
  },
  {
    file = "runtime_list_projects_items.txt",
    render = function()
      return golden_run("operation", {
        { body = fixtures.bodies.page({ "a", "b" }, "c1") },
        { body = fixtures.bodies.page({ "c" }) },
      }, function(c)
        must(c:list_projects_items({ limit = 2 }):collect())
      end)
    end,
  },
  {
    file = "runtime_get_project_not_found.txt",
    render = function()
      return golden_run(
        "debug",
        { { status = 404, body = { message = "no such project" } } },
        function(c)
          c:get_project({ project_id = "missing" })
        end
      )
    end,
  },
}

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

t.describe("client: golden traces", function()
  local write = os.getenv and os.getenv("DL_GOLDEN_WRITE") == "1"
  for _, case in ipairs(GOLDEN) do
    t.it("matches spec/golden/trace/" .. case.file, function()
      local path = t.root .. "/spec/golden/trace/" .. case.file
      local actual = case.render()
      if write then
        local f = assert(io.open(path, "wb"))
        f:write(actual)
        f:close()
      end
      local expected = read_file(path)
      if expected == nil then
        t.fail(
          "golden file missing: " .. path .. " (DL_GOLDEN_WRITE=1 lua spec/run.lua client_spec)"
        )
      end
      t.eq(actual, expected)
    end)
  end
end)
