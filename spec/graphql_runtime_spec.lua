-- distilled.graphql: the Query algebra, the compiler, reading responses, error
-- classification and Relay pagination. The first groups port
-- ../distilled/packages/core/test/graphql.test.ts case by case (named after them); the
-- rest cover what the Lua surface adds or the TS tests leave out.
local t = require("spec.harness")
local errors = require("distilled.errors")
local graphql = require("distilled.graphql")
local json = require("distilled.json")
local secret = require("distilled.secret")

local null = json.null
local F = graphql.field

local function A(t_)
  return json.array(t_)
end

-- run a plan against scripted responses (a response table, or fn(compiled, n) -> response)
local function runner(respond)
  local sent = {}
  local function execute(compiled)
    sent[#sent + 1] = compiled
    local response = respond
    if type(respond) == "function" then
      response = respond(compiled, #sent)
    end
    return graphql.result(compiled, response)
  end
  return execute, sent
end

local function run(plan, respond)
  local execute, sent = runner(respond)
  local value, err = graphql.evaluate(plan, execute)
  return value, err, sent
end

-- the schema of graphql.test.ts
local User = graphql.type_meta("User")
local Project = graphql.type_meta("Project")
User.fields.email = F("email", "scalar")
User.fields.name = F("name", "scalar")
User.fields.projects = F("projects", "list", Project, { { "first", "Int" } })
Project.fields.name = F("name", "scalar")
Project.fields.stars = F("stars", "scalar")

local function me()
  return graphql.root({ op = "query", field = "me", shape = "root", meta = User })
end

t.describe("graphql: Query.fn (graphql.test.ts)", function()
  t.it("builds one document from a returned plan and maps/filters after fetch", function()
    local m = me()
    local plan = {
      email = m.email,
      projects = graphql.map(
        graphql.filter(m.projects({ first = 5 }), function(p)
          return graphql.map(p.stars, function(stars)
            return stars > 5
          end)
        end),
        function(p)
          return { name = p.name, stars = p.stars }
        end
      ),
    }
    local value, err, sent = run(plan, {
      data = {
        me = {
          email = "ada@railway.app",
          projects = A({ { name = "engine", stars = 12 }, { name = "bombe", stars = 3 } }),
        },
      },
    })
    t.eq(err, nil)
    t.eq(#sent, 1)
    t.match(sent[1].document, "email", true)
    t.match(sent[1].document, "stars", true)
    t.match(sent[1].document, "name", true)
    t.same(value, { email = "ada@railway.app", projects = { { name = "engine", stars = 12 } } })
  end)

  t.it("Relay connections map as a list of nodes, one POST", function()
    local Workspace = graphql.type_meta("Workspace", { name = F("name", "scalar") })
    local page = graphql.root({
      op = "query",
      field = "projects",
      shape = "connection",
      meta = Workspace,
      args = { first = 20 },
      arg_order = { { "first", "Int" } },
    })
    local names, err, sent = run(
      graphql.map(page, function(p)
        return p.name
      end),
      {
        data = {
          projects = {
            edges = A({ { node = { name = "engine" } }, { node = { name = "bombe" } } }),
          },
        },
      }
    )
    t.eq(err, nil)
    t.eq(#sent, 1)
    t.match(sent[1].document, "edges", true)
    t.match(sent[1].document, "node", true)
    t.no_match(sent[1].document, "pageInfo", true)
    t.same(names, { "engine", "bombe" })
  end)

  t.it("nested connection fields unwrap edges.node", function()
    local Service = graphql.type_meta("Service", { name = F("name", "scalar") })
    local P = graphql.type_meta("Project", {
      name = F("name", "scalar"),
      services = F("services", "connection", Service, { { "first", "Int" } }),
    })
    local project = graphql.root({
      op = "query",
      field = "project",
      shape = "root",
      meta = P,
      args = { id = "p1" },
      arg_order = { { "id", "String!" } },
    })
    local value, err, sent = run({
      name = project.name,
      services = graphql.map(project.services({ first = 20 }), function(s)
        return s.name
      end),
    }, {
      data = {
        project = {
          name = "engine",
          services = { edges = A({ { node = { name = "web" } }, { node = { name = "db" } } }) },
        },
      },
    })
    t.eq(err, nil)
    t.match(sent[1].document, "services[%s%S]*edges[%s%S]*node")
    t.same(value, { name = "engine", services = { "web", "db" } })
  end)

  t.it("object and scalar fields with arguments bind them as variables", function()
    local Account = graphql.type_meta("Account", {
      name = F("name", "scalar"),
      avatarUrl = F("avatarUrl", "scalar", nil, { { "size", "Int" } }),
    })
    local AccountQuery = graphql.type_meta("AccountQuery", {
      byId = F("byId", "object", Account, { { "accountId", "String!" } }),
      agreed = F("agreed", "scalar", nil, { { "providerName", "String!" } }),
    })
    local account =
      graphql.root({ op = "query", field = "account", shape = "root", meta = AccountQuery })
    local by_id = account.byId({ accountId = "a1" })
    local plan = {
      name = by_id.name,
      small = by_id.avatarUrl({ size = 64 }),
      avatar = by_id.avatarUrl,
      agreed = account.agreed({ providerName = "tigris" }),
    }
    local compiled = assert(graphql.compile(plan))
    -- keys are visited sorted: agreed, avatar, name, small; so the bare avatarUrl comes
    -- first and the sized one is the alias
    local value, err, sent = run(plan, {
      data = {
        account = {
          byId = { name = "acme", avatarUrl = "https://a", avatarUrl_0 = "https://a/64" },
          agreed = true,
        },
      },
    })
    t.eq(err, nil)
    t.same(value, { name = "acme", small = "https://a/64", avatar = "https://a", agreed = true })
    t.match(sent[1].document, "byId%(accountId: %$v%d+%)")
    t.match(sent[1].document, "avatarUrl_0: avatarUrl%(size: %$v%d+%)")
    t.match(sent[1].document, "agreed%(providerName: %$v%d+%)")
    local values = {}
    for _, v in pairs(compiled.variables) do
      values[#values + 1] = tostring(v)
    end
    table.sort(values)
    t.same(values, { "64", "a1", "tigris" })
  end)

  t.it("Query.map on an object selects its fields and keeps null", function()
    local Deployment = graphql.type_meta("Deployment", {
      id = F("id", "scalar"),
      status = F("status", "scalar"),
    })
    local Service = graphql.type_meta("Service", {
      name = F("name", "scalar"),
      latestDeployment = F("latestDeployment", "object", Deployment),
    })
    local service =
      graphql.root({ op = "query", field = "service", shape = "root", meta = Service })
    local plan = {
      name = service.name,
      deployment = graphql.map(service.latestDeployment, function(d)
        return { id = d.id, status = d.status }
      end),
    }
    local value, err, sent = run(plan, {
      data = { service = { name = "web", latestDeployment = { id = "d1", status = "SUCCESS" } } },
    })
    t.eq(err, nil)
    t.same(value, { name = "web", deployment = { id = "d1", status = "SUCCESS" } })
    t.match(sent[1].document, "latestDeployment {%s+id%s+status")
    value = run(plan, { data = { service = { name = "web", latestDeployment = null } } })
    t.eq(value.deployment, null)
    t.eq(value.name, "web")
  end)
end)

-- sensitive fields (graphql.test.ts "sensitive fields")
local Credentials = graphql.type_meta("Credentials", {
  accessKeyId = F("accessKeyId", "scalar"),
  secretAccessKey = F("secretAccessKey", "scalar", nil, nil, true),
})
local NotFound = errors.define({ tag = "NotFound" })
local Forbidden = errors.define({ tag = "Forbidden" })
local SPECS = {
  graphql.error_spec(NotFound, { { code = "NOT_FOUND" } }),
  graphql.error_spec(Forbidden, { { code = "FORBIDDEN" } }),
}
local function credentials(errs)
  return graphql.root({
    op = "query",
    field = "credentials",
    shape = "list",
    meta = Credentials,
    errors = errs,
  })
end
local function rows()
  return A({ { accessKeyId = "AKID", secretAccessKey = "secret-value" } })
end
local function no_secret_in(v)
  t.no_match(json.encode(secret.unwrap_deep(v)) and "" or "", "secret-value", true)
  -- a secret cannot be encoded at all: walk and check every string
  local stack = { v }
  while #stack > 0 do
    local x = table.remove(stack)
    if type(x) == "string" then
      t.no_match(x, "secret", true)
    elseif type(x) == "table" and not secret.is(x) then
      for _, y in pairs(x) do
        stack[#stack + 1] = y
      end
    end
  end
end

t.describe("graphql: sensitive fields (graphql.test.ts)", function()
  t.it("a marked field decodes as a secret and other fields stay plain", function()
    local value, err = run({
      rows = graphql.map(credentials(), function(row)
        return { accessKeyId = row.accessKeyId, secretAccessKey = row.secretAccessKey }
      end),
    }, { data = { credentials = rows() } })
    t.eq(err, nil)
    local row = value.rows[1]
    t.eq(row.accessKeyId, "AKID")
    t.truthy(secret.is(row.secretAccessKey))
    t.eq(secret.unwrap(row.secretAccessKey), "secret-value")
    no_secret_in(value)
  end)

  t.it("rows returned whole keep a marked field as a secret", function()
    local value, err = run({
      filtered = graphql.filter(credentials(), function(row)
        return graphql.map(row.secretAccessKey, function(s)
          return secret.is(s)
        end)
      end),
      whole = graphql.map(credentials(), function(row)
        return { id = row.accessKeyId, row = row }
      end),
    }, { data = { credentials = rows() } })
    t.eq(err, nil)
    t.eq(#value.filtered, 1)
    t.truthy(secret.is(value.filtered[1].secretAccessKey))
    t.truthy(secret.is(value.whole[1].row.secretAccessKey))
    no_secret_in(value)
  end)

  t.it("a marked field under a nested object, an alias and a connection is a secret", function()
    local Bucket = graphql.type_meta("Bucket", {
      name = F("name", "scalar"),
      credentials = F("credentials", "object", Credentials),
    })
    local function node(name, s)
      return { name = name, credentials = { accessKeyId = name .. "-key", secretAccessKey = s } }
    end
    local requests = {}
    local execute = function(compiled)
      requests[#requests + 1] = compiled.variables
      if not string.find(compiled.document, "buckets", 1, true) then
        return graphql.result(compiled, {
          data = { bucket = node("one", "secret-one"), bucket_0 = node("two", "secret-two") },
        })
      end
      local first = #requests == 2
      return graphql.result(compiled, {
        data = {
          buckets = {
            edges = A({ { node = first and node("a", "secret-a") or node("b", "secret-b") } }),
            pageInfo = { hasNextPage = first, endCursor = first and "c1" or null },
          },
        },
      })
    end
    local function bucket(token)
      return graphql.root({
        op = "query",
        field = "bucket",
        shape = "root",
        meta = Bucket,
        args = { token = secret.wrap(token) },
        arg_order = { { "token", "String!" } },
      })
    end
    local secrets, err = graphql.evaluate({
      one = graphql.map(bucket("t-one"), function(row)
        return { name = row.name, secret = row.credentials.secretAccessKey }
      end),
      two = bucket("t-two").credentials.secretAccessKey,
    }, execute)
    t.eq(err, nil)
    t.same(requests[1], { v0 = "t-one", v1 = "t-two" })
    t.eq(secrets.one.name, "one")
    t.eq(secret.unwrap(secrets.one.secret), "secret-one")
    t.eq(secret.unwrap(secrets.two), "secret-two")
    local buckets = graphql.root({
      op = "query",
      field = "buckets",
      shape = "connection",
      meta = Bucket,
      args = { first = 1 },
      arg_order = { { "first", "Int" }, { "after", "String" } },
    })
    local items, ierr = graphql
      .pages(
        graphql.map(buckets, function(row)
          return row.credentials.secretAccessKey
        end),
        execute,
        "items"
      )
      :collect()
    t.eq(ierr, nil)
    t.eq(#requests, 3)
    t.eq(secret.unwrap(items[1]), "secret-a")
    t.eq(secret.unwrap(items[2]), "secret-b")
    t.same(requests[3], { v0 = 1, v1 = "c1" })
  end)

  t.it("a marked JSON scalar decodes whole as a secret", function()
    local AddOn = graphql.type_meta("AddOn", {
      name = F("name", "scalar"),
      environment = F("environment", "scalar", nil, nil, true),
    })
    local add_on = graphql.root({ op = "query", field = "addOn", shape = "root", meta = AddOn })
    local value, err = run({ name = add_on.name, environment = add_on.environment }, {
      data = {
        addOn = { name = "bucket", environment = { AWS_SECRET_ACCESS_KEY = "secret-value" } },
      },
    })
    t.eq(err, nil)
    t.truthy(secret.is(value.environment))
    t.same(secret.unwrap(value.environment), { AWS_SECRET_ACCESS_KEY = "secret-value" })
    no_secret_in(value)
  end)

  t.it("a marked leaf root decodes each string as a secret and keeps null", function()
    local function token(list)
      return graphql.root({
        op = "mutation",
        field = "tokenCreate",
        shape = list and "leaf_list" or "leaf",
        sensitive = true,
      })
    end
    local one = run(token(false), { data = { tokenCreate = "token-value" } })
    t.eq(secret.unwrap(one), "token-value")
    local many = run(token(true), { data = { tokenCreate = A({ "a-code", "b-code" }) } })
    t.truthy(secret.is(many[1]))
    t.truthy(secret.is(many[2]))
    local none = run(token(false), { data = { tokenCreate = null } })
    t.eq(none, null)
  end)

  t.it("a failure keeps the response data with marked fields as secrets", function()
    local v, err = run(
      graphql.map(credentials(SPECS), function(row)
        return row.secretAccessKey
      end),
      {
        data = { credentials = rows() },
        errors = A({
          {
            message = "missing",
            path = A({ "credentials", 1 }),
            extensions = { code = "NOT_FOUND" },
          },
          {
            message = "denied",
            path = A({ "credentials", 2 }),
            extensions = { code = "FORBIDDEN" },
          },
        }),
      }
    )
    t.err(v, err, "GraphQLFailure")
    t.eq(err.data.credentials[1].accessKeyId, "AKID")
    t.truthy(secret.is(err.data.credentials[1].secretAccessKey))
    t.eq(err.message, "NotFound at credentials.1: missing; Forbidden at credentials.2: denied")
    t.eq(#err.errors, 2)
    t.eq(err.errors[1].tag, "NotFound")
    no_secret_in(err.data)
  end)
end)

t.describe("graphql: secret arguments (graphql.test.ts)", function()
  t.it("a secret in a request argument is sent as its plain value", function()
    local function upsert(s)
      return graphql.root({
        op = "mutation",
        field = "variableCollectionUpsert",
        shape = "leaf",
        args = { input = { variables = { S3_SECRET = s } } },
        arg_order = { { "input", "VariableCollectionUpsertInput!" } },
      })
    end
    local _, err, sent = run({
      a = upsert(secret.wrap("first-secret")),
      b = upsert(secret.wrap("second-secret")),
    }, {
      data = { a = true, variableCollectionUpsert = true, variableCollectionUpsert_0 = true },
    })
    t.eq(err, nil)
    t.same(sent[1].variables, {
      v0 = { variables = { S3_SECRET = "first-secret" } },
      v1 = { variables = { S3_SECRET = "second-secret" } },
    })
    -- the arguments as given keep the secret (span attributes read these)
    t.truthy(secret.is(sent[1].raw_variables.v0.variables.S3_SECRET))
  end)
end)

t.describe("graphql: malformed responses fail with typed errors (graphql.test.ts)", function()
  local NF = errors.define({ tag = "NotFound" })
  local errs = { graphql.error_spec(NF, { { code = "NOT_FOUND" } }) }
  local function ping(response)
    local v, err = run(
      graphql.root({ op = "mutation", field = "ping", shape = "leaf", errors = errs }),
      response
    )
    t.eq(v, nil)
    return err
  end

  t.it("a response without data and errors is a GraphQLTransportError", function()
    for _, r in ipairs({ {}, { data = null }, { data = null, errors = A({}) } }) do
      t.eq(ping(r).tag, "GraphQLTransportError")
      t.eq(ping(r).message, "GraphQL response has no data object and no errors")
    end
  end)

  t.it("an errors entry that is not an object is an UnknownGraphQLError", function()
    local cases = {
      { null, "malformed GraphQL error entry (null)" },
      { 42, "malformed GraphQL error entry (number)" },
      { "boom", "boom" },
    }
    for _, c in ipairs(cases) do
      local err = ping({ data = null, errors = A({ c[1] }) })
      t.eq(err.tag, "UnknownGraphQLError")
      t.eq(err.message, c[2])
    end
  end)

  t.it(
    "a path with a non-string, non-number element is left out; its root still classifies",
    function()
      local err = ping({
        data = null,
        errors = A({
          { message = "gone", path = A({ "ping", null }), extensions = { code = "NOT_FOUND" } },
        }),
      })
      t.eq(err.tag, "NotFound")
      t.eq(err.path, nil)
    end
  )

  t.it("malformed locations are left out", function()
    for _, locations in ipairs({ A({ { line = "1", column = 2 } }), A({ null }), "1:2" }) do
      local err = ping({ data = null, errors = A({ { message = "bad", locations = locations } }) })
      t.eq(err.tag, "UnknownGraphQLError")
      t.eq(err.locations, nil)
    end
  end)

  t.it("well-formed path and locations are kept", function()
    local err = ping({
      data = null,
      errors = A({
        { message = "bad", path = A({ "ping", 0 }), locations = A({ { line = 1, column = 2 } }) },
      }),
    })
    t.eq(err.tag, "UnknownGraphQLError")
    t.same(err.path, { "ping", 0 })
    t.same(err.locations, { { line = 1, column = 2 } })
    t.eq(err.coordinate, "ping")
  end)
end)

t.describe("graphql: classification (core graphql.ts classify)", function()
  local RateLimited =
    graphql.error_class({ tag = "RateLimited", category = "throttling", retryable = true })
  local Invalid = graphql.error_class({ tag = "Invalid", category = "badRequest" })
  local Missing = graphql.error_class({ tag = "Missing", category = "notFound" })
  local Own = graphql.error_class({ tag = "Own" })
  local global = {
    graphql.error_spec(
      RateLimited,
      { { code = "RATELIMITED" } },
      { retryable = true, global = true }
    ),
    graphql.error_spec(Invalid, { { code = "INPUT_ERROR" } }, { global = true }),
    graphql.error_spec(
      Missing,
      { { code = "INPUT_ERROR", messageIncludes = "Entity not found" } },
      { global = true }
    ),
  }
  local own = { graphql.error_spec(Own, { { message = "exactly this" } }) }
  for _, s in ipairs(global) do
    own[#own + 1] = s
  end
  local function issue()
    return graphql.root({ op = "query", field = "issue", shape = "leaf", errors = own })
  end
  local function classify(entry, response)
    local compiled = assert(graphql.compile(issue()))
    response = response or {}
    return graphql.classify(compiled, entry, response)
  end

  t.it("the most specific matcher wins (messageIncludes over a bare code)", function()
    local e =
      classify({ message = "Entity not found: Issue", extensions = { code = "INPUT_ERROR" } })
    t.eq(e.tag, "Missing")
    t.truthy(e.categories.NotFoundError)
    t.eq(classify({ message = "bad", extensions = { code = "INPUT_ERROR" } }).tag, "Invalid")
  end)

  t.it("an exact message outranks a code; errorCode is read when code is absent", function()
    t.eq(classify({ message = "exactly this", path = A({ "issue" }) }).tag, "Own")
    t.eq(classify({ message = "x", extensions = { errorCode = "RATELIMITED" } }).tag, "RateLimited")
  end)

  t.it("an error with no path is matched against the global errors only", function()
    t.eq(classify({ message = "exactly this" }).tag, "UnknownGraphQLError")
  end)

  t.it("a tie between different tags stays UnknownGraphQLError", function()
    local A1 = errors.define({ tag = "A1" })
    local B1 = errors.define({ tag = "B1" })
    local specs =
      { graphql.error_spec(A1, { { code = "X" } }), graphql.error_spec(B1, { { code = "X" } }) }
    local compiled = assert(
      graphql.compile(graphql.root({ op = "query", field = "f", shape = "leaf", errors = specs }))
    )
    local e = graphql.classify(
      compiled,
      { message = "m", path = A({ "f" }), extensions = { code = "X" } },
      {}
    )
    t.eq(e.tag, "UnknownGraphQLError")
    t.eq(e.coordinate, "f")
  end)

  t.it("instance fields: code, status, retry_after (seconds), the server trace id", function()
    local e = classify(
      { message = "slow down", extensions = { code = "RATELIMITED", traceId = "tr-1" } },
      { status = 400, headers = { ["retry-after"] = "2.5" } }
    )
    t.eq(e.tag, "RateLimited")
    t.eq(e.code, "RATELIMITED")
    t.eq(e.status, 400)
    t.eq(e.retry_after, 2.5)
    t.eq(e.server_trace_id, "tr-1")
    t.truthy(e.retryable)
    t.truthy(e.throttling)
    t.eq(classify({ message = "x", traceId = "top" }).server_trace_id, "top")
    t.eq(
      classify({ message = "x" }, { headers = { ["retry-after"] = "Tue, 1 Jan" } }).retry_after,
      nil
    )
  end)

  t.it(
    "errors with one tag are the first error itself; retryable follows the roots' specs",
    function()
      local compiled = assert(graphql.compile(issue()))
      local _, err = graphql.result(compiled, {
        errors = A({
          { message = "a", extensions = { code = "RATELIMITED" } },
          { message = "b", extensions = { code = "RATELIMITED" } },
        }),
      })
      t.eq(err.tag, "RateLimited")
      t.eq(err.message, "a")
      t.truthy(graphql.is_retryable(compiled, err))
      local _, mixed = graphql.result(compiled, {
        errors = A({
          { message = "a", extensions = { code = "RATELIMITED" } },
          { message = "b", extensions = { code = "INPUT_ERROR" } },
        }),
      })
      t.eq(mixed.tag, "GraphQLFailure")
      t.falsy(graphql.is_retryable(compiled, mixed))
      local te = errors.new(graphql.GraphQLTransportError, { message = "x" })
      t.truthy(graphql.is_retryable(compiled, te))
      te.status = 429
      t.truthy(graphql.is_retryable(compiled, te))
      te.status = 503
      t.truthy(graphql.is_retryable(compiled, te))
      te.status = 400
      t.falsy(graphql.is_retryable(compiled, te))
      t.falsy(graphql.is_retryable(compiled, errors.new("ConfigError", {})))
    end
  )
end)

t.describe("graphql: compiling", function()
  t.it("unknown fields and arguments raise at build time (misuse)", function()
    t.raises(function()
      return me().nope
    end, "User has no field nope")
    t.raises(function()
      return me().projects({ firts = 1 })
    end, "takes no argument firts %(valid: first%)")
    t.raises(function()
      return me().email({ x = 1 })
    end, "takes no argument x %(it takes none%)")
    t.raises(function()
      return me().projects(42)
    end, "must be a table")
    t.raises(function()
      graphql.map(42, function() end)
    end, "expected a Query")
  end)

  t.it("one document cannot mix a query and a mutation", function()
    local m = graphql.root({ op = "mutation", field = "ping", shape = "leaf" })
    local c, err = graphql.compile({ a = me().email, b = m })
    t.eq(c, nil)
    t.eq(err.tag, "GqlError")
    t.eq(err.message, "cannot mix query and mutation in one document")
  end)

  t.it("an object read without a field has no sub-selection", function()
    local _, err = graphql.compile({ me = me() })
    t.eq(err.tag, "GqlError")
    t.eq(err.message, 'field "me" has no sub-selection')
  end)

  t.it("a plan with no Query sends nothing and returns its literals", function()
    local value, err, sent = run({ a = 1, b = graphql.of("x"), c = { d = json.null } }, {})
    t.eq(err, nil)
    t.eq(#sent, 0)
    t.eq(value.a, 1)
    t.eq(value.b, "x")
    t.eq(value.c.d, json.null)
  end)

  t.it("the document text: header, variables, two-space indentation, mutation kind", function()
    local m = graphql.root({
      op = "mutation",
      field = "ping",
      shape = "leaf",
      args = { n = 1, s = "x" },
      arg_order = { { "s", "String" }, { "n", "Int!" } },
    })
    local c = assert(graphql.compile(m))
    t.eq(c.document, "mutation Gql($v0: String, $v1: Int!) {\n  ping(s: $v0, n: $v1)\n}")
    t.eq(c.kind, "mutation")
    t.eq(c.operation_name, "Gql")
    local q = assert(graphql.compile(me().email))
    t.eq(q.document, "query Gql {\n  me {\n    email\n  }\n}")
    t.eq(json.encode(q.variables), "{}")
  end)

  t.it(
    "the same field with the same arguments is one selection; other arguments alias it",
    function()
      local c = assert(graphql.compile({
        a = me().projects({ first = 1 }).name,
        b = me().projects({ first = 1 }).stars,
        c = me().projects({ first = 2 }).name,
      }))
      t.eq(
        c.document,
        "query Gql($v0: Int, $v1: Int) {\n  me {\n    projects(first: $v0) {\n      name\n      stars\n    }\n"
          .. "    projects_0: projects(first: $v1) {\n      name\n    }\n  }\n}"
      )
    end
  )

  t.it("deep plans fail with GqlError, not a stack overflow", function()
    local plan = {}
    local at = plan
    for _ = 1, graphql.MAX_DEPTH + 5 do
      at.x = {}
      at = at.x
    end
    at.q = me().email
    local c, err = graphql.compile(plan)
    t.eq(c, nil)
    t.eq(err.tag, "GqlError")
    t.match(err.message, "nested deeper than")
  end)
end)

t.describe("graphql: flat_map and callbacks", function()
  t.it("flat_map runs after the POST with the value; a returned plan is another request", function()
    local n = 0
    local value, err, sent = run(
      graphql.flat_map(me().email, function(email)
        n = n + 1
        if email == "ada@x" then
          return { again = me().name, email = email }
        end
        return email
      end),
      function(compiled, i)
        if i == 1 then
          return { data = { me = { email = "ada@x" } } }
        end
        return { data = { me = { name = "Ada" } } }
      end
    )
    t.eq(err, nil)
    t.eq(n, 1)
    t.eq(#sent, 2)
    t.same(value, { again = "Ada", email = "ada@x" })
  end)

  t.it("flat_map returning nil, err fails the run with err", function()
    local boom = errors.new("ConfigError", { message = "no" })
    local v, err = run(
      graphql.flat_map(me().email, function()
        return nil, boom
      end),
      { data = { me = { email = "e" } } }
    )
    t.eq(v, nil)
    t.eq(err, boom)
  end)

  t.it("a raise in a map or flat_map callback after the POST is an SdkError", function()
    local v, err = run(
      graphql.map(me().email, function()
        error("bad callback", 0)
      end),
      { data = { me = { email = "e" } } }
    )
    t.eq(v, nil)
    t.eq(err.tag, "SdkError")
    t.match(err.message, "the map callback raised: bad callback", true)
  end)

  t.it("flat_map inside a map is refused", function()
    local v, err = run(
      graphql.map(me().projects, function(p)
        return graphql.flat_map(p.name, function(x)
          return x
        end)
      end),
      { data = { me = { projects = A({ { name = "a" } }) } } }
    )
    t.eq(v, nil)
    t.eq(err.tag, "GqlError")
  end)

  t.it("JavaScript truthiness in filter predicates", function()
    local value = run(
      graphql.filter(me().projects, function(p)
        return p.stars
      end),
      {
        data = {
          me = { projects = A({ { stars = 0 }, { stars = null }, { stars = 3 }, { stars = "" } }) },
        },
      }
    )
    t.eq(#value, 1)
    t.eq(value[1].stars, 3)
  end)

  t.it("fields read through a list map over the items; nulls stay as json.null", function()
    local value = run(me().projects.name, {
      data = { me = { projects = A({ { name = "a" }, null, { name = "c" } }) } },
    })
    t.eq(#value, 3)
    t.eq(value[2], null)
    t.eq(value[3], "c")
  end)
end)

t.describe("graphql: pagination", function()
  local Team = graphql.type_meta("Team", { id = F("id", "scalar") })
  local Org = graphql.type_meta("Org", {
    teams = F("teams", "connection", Team, { { "first", "Int" }, { "after", "String" } }),
    list = F("list", "list", Team),
  })
  local function teams(args)
    return graphql.root({
      op = "query",
      field = "teams",
      shape = "connection",
      meta = Team,
      args = args,
      arg_order = { { "first", "Int" }, { "after", "String" } },
    })
  end
  -- the ids of a connection's nodes (a field read on a connection Query is not a
  -- connection any more: paging needs map, as in TS)
  local function ids(q)
    return graphql.map(q, function(x)
      return x.id
    end)
  end
  local function page(ids, more, cursor)
    local edges = {}
    for i, id in ipairs(ids) do
      edges[i] = { node = { id = id } }
    end
    return {
      data = {
        teams = { edges = A(edges), pageInfo = { hasNextPage = more, endCursor = cursor or null } },
      },
    }
  end

  t.it(
    "pages: one request per page, after set from endCursor, stops when hasNextPage is false",
    function()
      local execute, sent = runner(function(_, n)
        if n == 1 then
          return page({ "a", "b" }, true, "c1")
        end
        return page({ "c" }, false, "c2")
      end)
      local it = graphql.pages(
        graphql.map(teams({ first = 2 }), function(x)
          return x.id
        end),
        execute,
        "pages"
      )
      local pages = {}
      for p in it do
        pages[#pages + 1] = p
      end
      t.eq(it.err, nil)
      t.same(pages, { { "a", "b" }, { "c" } })
      t.eq(#sent, 2)
      t.match(sent[1].document, "pageInfo {\n      hasNextPage\n      endCursor\n    }", true)
      t.same(sent[1].variables, { v0 = 2 })
      t.same(sent[2].variables, { v0 = 2, v1 = "c1" })
      t.eq(it.pages, 2)
    end
  )

  t.it("items: every node across pages; collect(limit) stops early", function()
    local execute, sent = runner(function(_, n)
      return page({ "x" .. n, "y" .. n }, n < 3, "c" .. n)
    end)
    local items = graphql.pages(ids(teams({ first = 2 })), execute, "items"):collect()
    t.same(items, { "x1", "y1", "x2", "y2", "x3", "y3" })
    t.eq(#sent, 3)
    local execute2, sent2 = runner(function(_, n)
      return page({ "x" .. n, "y" .. n }, true, "c" .. n)
    end)
    local three = graphql.pages(ids(teams({ first = 2 })), execute2, "items"):collect(3)
    t.same(three, { "x1", "y1", "x2" })
    t.eq(#sent2, 2)
  end)

  t.it("the query's own after argument is the first cursor", function()
    local execute, sent = runner(page({ "a" }, false))
    graphql.pages(ids(teams({ first = 1, after = "start" })), execute):collect()
    t.same(sent[1].variables, { v0 = 1, v1 = "start" })
  end)

  t.it(
    "a non-advancing cursor fails with GraphQLPaginationError (that page is not handed out)",
    function()
      local execute = runner(function(_, n)
        return page({ "p" .. n }, true, n == 1 and "c1" or "c1")
      end)
      local it = graphql.pages(ids(teams({ first = 1 })), execute, "items")
      local got = {}
      for x in it do
        got[#got + 1] = x
      end
      t.same(got, { "p1" })
      t.eq(it.err.tag, "GraphQLPaginationError")
      t.eq(it.err.cursor, "c1")
      t.match(it.err.message, "returned a non-advancing cursor", true)
      local execute2 = runner(page({ "a" }, true, nil))
      local list, err = graphql.pages(ids(teams({ first = 1 })), execute2):collect()
      t.eq(list, nil)
      t.eq(err.cursor, null)
    end
  )

  t.it("paging something that is not a connection, or takes no after, is a GqlError", function()
    local org = graphql.root({ op = "query", field = "org", shape = "root", meta = Org })
    local _, e1 = graphql.pages(org.list.id, runner({})):collect()
    t.eq(e1.tag, "GqlError")
    t.match(e1.message, "pages needs a Relay connection", true)
    local bare = graphql.root({ op = "query", field = "teams", shape = "connection", meta = Team })
    local _, e2 = graphql.pages(ids(bare), runner({})):collect()
    t.eq(e2.message, 'teams takes no "after" cursor')
  end)

  t.it("a failing page stops the iterator with the error", function()
    local execute = runner(function(_, n)
      if n == 1 then
        return page({ "a" }, true, "c1")
      end
      return { errors = A({ { message = "boom" } }) }
    end)
    local list, err = graphql.pages(ids(teams({ first = 1 })), execute, "items"):collect()
    t.eq(list, nil)
    t.eq(err.tag, "UnknownGraphQLError")
    t.eq(err.message, "boom")
  end)
end)
