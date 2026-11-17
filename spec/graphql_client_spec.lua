-- The generated GraphQL clients (clients/linear, railway, expo_eas, github/graphql,
-- fly_io/graphql) over the scripted transport: the HTTP request each provider's
-- graphql-transport.ts and credentials.ts would send, the transport failures, retries,
-- error classes, pagination and the document spans.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local trace = require("distilled.trace")
local gql = require("distilled.graphql")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Linear = require("linear")
local Railway = require("railway")
local Eas = require("expo_eas")
local GitHub = require("github.graphql")
local Fly = require("fly_io.graphql")

local null = json.null

local function ok(data, headers)
  return { status = 200, body = { data = data }, headers = headers }
end

local function client(Class, responses, opts)
  opts = opts or {}
  local host = testing.host({ responses = responses, env = opts.env or {} })
  local o = { host = host }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  return Class.new(o), host
end

local function body_of(req)
  return assert(json.decode(req.body))
end

t.describe("graphql clients: generated modules", function()
  t.it("each module has its roots, error classes and a client class", function()
    t.eq(#Linear.roots(), 494)
    t.eq(#Railway.roots(), 445)
    t.eq(#Eas.roots(), 145)
    t.eq(#GitHub.roots(), 308)
    t.eq(#Fly.roots(), 125)
    t.eq(Linear.errors.LinearRateLimited.tag, "LinearRateLimited")
    t.truthy(Linear.errors.LinearRateLimited.retryable)
    t.truthy(Linear.errors.LinearRateLimited.throttling)
    t.truthy(Linear.errors.LinearAuthenticationError.categories.AuthError)
    t.eq(Linear.nope, nil)
    t.raises(function()
      Linear.x = 1
    end, "read%-only")
    local c = Linear.new({ api_key = "k" })
    for _, m in ipairs({ "run", "pages", "items", "with", "close", "compile" }) do
      t.eq(type(c[m]), "function", m)
    end
    t.raises(function()
      Linear.new({ nope = 1 })
    end, "unknown option nope")
  end)

  t.it("a mutation that shares a query's name is exported with a Mutation suffix", function()
    -- none of the five schemas has one; the rule is the generator's (graphql-client.ts)
    local gen = require("distilled.gen.graphql")
    t.eq(gen._peel("[String!]!").name, "String")
    t.truthy(gen._peel("[String!]!").list)
  end)
end)

t.describe("graphql clients: the request", function()
  t.it("Linear: POST <base>/graphql, a personal API key sent bare, the JSON body", function()
    local c, host = client(
      Linear,
      { ok({ viewer = { email = "ada@x" } }) },
      { api_key = " lin_key " }
    )
    local v, err = c:run({ email = Linear.viewer().email })
    t.eq(err, nil)
    t.same(v, { email = "ada@x" })
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://api.linear.app/graphql")
    t.eq(req.headers.authorization, "lin_key")
    t.eq(req.headers.accept, "application/graphql-response+json, application/json")
    t.eq(req.headers["content-type"], "application/json")
    local body = body_of(req)
    t.eq(body.query, "query Gql {\n  viewer {\n    email\n  }\n}")
    t.eq(body.operationName, "Gql")
    t.eq(json.encode(body.variables), "{}")
  end)

  t.it(
    "Linear: an OAuth token is Bearer; the API key wins; env variables; empty means none",
    function()
      local c, host = client(
        Linear,
        { ok({ viewer = { id = "1" } }) },
        { access_token = "oauth-t" }
      )
      assert(c:run(Linear.viewer().id))
      t.eq(host.requests[1].headers.authorization, "Bearer oauth-t")
      c, host = client(Linear, { ok({ viewer = { id = "1" } }) }, {
        env = {
          LINEAR_API_KEY = "envkey",
          LINEAR_ACCESS_TOKEN = "envtok",
          LINEAR_API_URL = "https://l.test/",
        },
      })
      assert(c:run(Linear.viewer().id))
      t.eq(host.requests[1].headers.authorization, "envkey")
      t.eq(host.requests[1].url, "https://l.test/graphql")
      c, host = client(
        Linear,
        { ok({ viewer = { id = "1" } }) },
        { env = { LINEAR_API_KEY = "", LINEAR_ACCESS_TOKEN = "t2" } }
      )
      assert(c:run(Linear.viewer().id))
      t.eq(host.requests[1].headers.authorization, "Bearer t2")
      c, host = client(Linear, { ok({ viewer = { id = "1" } }) }, { api_key = "   " })
      assert(c:run(Linear.viewer().id))
      t.eq(host.requests[1].headers.authorization, nil)
      c, host = client(
        Linear,
        { ok({ viewer = { id = "1" } }) },
        { api_key = secret.wrap("sk"), base_url = "https://x.test" }
      )
      assert(c:run(Linear.viewer().id))
      t.eq(host.requests[1].headers.authorization, "sk")
      t.eq(host.requests[1].url, "https://x.test/graphql")
    end
  )

  t.it("no credential at all is a ConfigError naming the variables; nothing is sent", function()
    local c, host = client(Linear, {})
    local v, err = c:run(Linear.viewer().id)
    t.err(v, err, "ConfigError")
    t.eq(err.message, "LINEAR_API_KEY (or LINEAR_ACCESS_TOKEN) environment variable is required")
    t.eq(err.key, "api_key")
    t.eq(#host.requests, 0)
  end)

  t.it(
    "Railway: /graphql/v2; account token Bearer (RAILWAY_TOKEN too); project token header",
    function()
      local c, host = client(
        Railway,
        { ok({ me = { email = "e" } }) },
        { env = { RAILWAY_TOKEN = "cli" } }
      )
      assert(c:run(Railway.me().email))
      t.eq(host.requests[1].url, "https://backboard.railway.com/graphql/v2")
      t.eq(host.requests[1].headers.authorization, "Bearer cli")
      c, host = client(
        Railway,
        { ok({ me = { email = "e" } }) },
        { env = { RAILWAY_PROJECT_TOKEN = "proj" } }
      )
      assert(c:run(Railway.me().email))
      t.eq(host.requests[1].headers["project-access-token"], "proj")
      t.eq(host.requests[1].headers.authorization, nil)
      c, host = client(Railway, { ok({ me = { email = "e" } }) }, {
        env = { RAILWAY_API_TOKEN = "acct", RAILWAY_PROJECT_TOKEN = "proj" },
      })
      assert(c:run(Railway.me().email))
      t.eq(host.requests[1].headers.authorization, "Bearer acct")
      t.eq(host.requests[1].headers["project-access-token"], nil)
    end
  )

  t.it("EAS: Bearer EXPO_TOKEN, EXPO_API_URL, Accept application/json", function()
    local c, host = client(Eas, { ok({ viewer = { username = "u" } }) }, {
      env = { EXPO_TOKEN = "expo-t", EXPO_API_URL = "https://staging-api.expo.dev" },
    })
    t.same(assert(c:run({ u = Eas.viewer().username })), { u = "u" })
    t.eq(host.requests[1].url, "https://staging-api.expo.dev/graphql")
    t.eq(host.requests[1].headers.authorization, "Bearer expo-t")
    t.eq(host.requests[1].headers.accept, "application/json")
  end)

  t.it("GitHub: GHES /api/v3 -> /api/graphql, GH_TOKEN, the User-Agent", function()
    local c, host = client(GitHub, { ok({ viewer = { login = "octo" } }) }, {
      env = { GH_TOKEN = "ghp", GITHUB_API_URL = "https://ghe.test/api/v3/" },
    })
    assert(c:run(GitHub.viewer().login))
    local req = host.requests[1]
    t.eq(req.url, "https://ghe.test/api/graphql")
    t.eq(req.headers.authorization, "Bearer ghp")
    t.eq(req.headers["user-agent"], "distilled.cloud-github")
    c, host = client(
      GitHub,
      { ok({ viewer = { login = "octo" } }) },
      { token = "t", user_agent = "me/1" }
    )
    assert(c:run(GitHub.viewer().login))
    t.eq(host.requests[1].url, "https://api.github.com/graphql")
    t.eq(host.requests[1].headers["user-agent"], "me/1")
  end)

  t.it("Fly: always https://api.fly.io/graphql, FLY_API_TOKEN or FLY_IO_API_KEY", function()
    local c, host = client(Fly, { ok({ viewer = { id = "v" } }) }, {
      env = { FLY_IO_API_KEY = "old", FLY_API_HOSTNAME = "https://elsewhere.test" },
    })
    assert(c:run(Fly.viewer().id))
    t.eq(host.requests[1].url, "https://api.fly.io/graphql")
    t.eq(host.requests[1].headers.authorization, "Bearer old")
  end)

  t.it("sensitive fields come back as secrets; secret arguments are sent plain", function()
    local c, host = client(Fly, {
      ok({ addOn = { password = "pw-secret", name = "b" } }),
    }, { api_key = "k" })
    local v = assert(c:run({
      pw = Fly.addOn({ name = secret.wrap("b") }).password,
      name = Fly.addOn({ name = secret.wrap("b") }).name,
    }))
    t.truthy(secret.is(v.pw))
    t.eq(secret.unwrap(v.pw), "pw-secret")
    t.eq(v.name, "b")
    t.same(body_of(host.requests[1]).variables, { v0 = "b" })
  end)
end)

t.describe("graphql clients: failures and retries", function()
  t.it(
    "GraphQL errors are classified by the SDK's classes (Linear 400 RATELIMITED is retried)",
    function()
      local limited = {
        status = 400,
        headers = { ["retry-after"] = "1" },
        body = { errors = { { message = "slow", extensions = { code = "RATELIMITED" } } } },
      }
      local c, host = client(
        Linear,
        { limited, limited, ok({ viewer = { id = "1" } }) },
        { api_key = "k" }
      )
      local v, err = c:run(Linear.viewer().id)
      t.eq(err, nil)
      t.eq(v, "1")
      t.eq(#host.requests, 3)
      t.same(host.sleeps, { 0.2, 0.4 })
    end
  )

  t.it("a query fails after 5 retries (200 ms doubling); a mutation is never retried", function()
    local bad = { status = 502, body = "<html>bad gateway</html>" }
    local responses = {}
    for i = 1, 6 do
      responses[i] = bad
    end
    local c, host = client(Linear, responses, { api_key = "k" })
    local v, err = c:run(Linear.viewer().id)
    t.err(v, err, "GraphQLTransportError")
    t.eq(err.message, "Linear HTTP 502 returned a non-GraphQL response")
    t.eq(err.status, 502)
    t.eq(#host.requests, 6)
    t.same(host.sleeps, { 0.2, 0.4, 0.8, 1.6, 3.2 })
    c, host = client(Linear, { bad }, { api_key = "k" })
    v, err = c:run(Linear.issueDelete({ id = "i" }).success)
    t.err(v, err, "GraphQLTransportError")
    t.eq(#host.requests, 1)
  end)

  t.it("retry = 'none' and { max_retries = 1 } replace the default", function()
    local bad = { status = 503, body = "" }
    local c, host = client(Linear, { bad }, { api_key = "k", retry = "none" })
    t.err(c:run(Linear.viewer().id))
    t.eq(#host.requests, 1)
    c, host = client(Linear, { bad, bad }, { api_key = "k", retry = { max_retries = 1 } })
    t.err(c:run(Linear.viewer().id))
    t.eq(#host.requests, 2)
  end)

  t.it("a non-retryable GraphQL error, and partial data, are not retried", function()
    local c, host = client(Railway, {
      ok({ project = null }),
    }, { api_token = "t" })
    host.transport.responses[1] = {
      status = 200,
      body = {
        data = { project = null },
        errors = {
          {
            message = "Project not found",
            path = { "project" },
            extensions = { code = "NOT_FOUND" },
          },
        },
      },
    }
    local v, err = c:run(Railway.project({ id = "p" }).name)
    t.eq(v, nil)
    t.eq(#host.requests, 1)
    -- RailwayNotFound is declared on the project root (a field error, not a global one)
    t.eq(err.tag, "RailwayNotFound")
    t.truthy(err.categories.NotFoundError)
    t.eq(err.path[1], "project")
    t.eq(err.message, "Project not found")
  end)

  t.it(
    "transport failures: not JSON, HTTP without errors (with the body's detail), network",
    function()
      local c = client(
        Linear,
        { { status = 200, body = "nope" } },
        { api_key = "k", retry = "none" }
      )
      local _, e1 = c:run(Linear.viewer().id)
      t.eq(e1.message, "Linear GraphQL response is not JSON")
      t.eq(e1.tag, "GraphQLTransportError")
      c = client(
        Eas,
        { { status = 401, body = { message = "Unauthorized token" } } },
        { access_token = "x" }
      )
      local _, e2 = c:run(Eas.viewer().id)
      t.eq(e2.message, "Eas HTTP 401: Unauthorized token")
      t.eq(e2.status, 401)
      c = client(Fly, { { status = 403, body = { error = "forbidden" } } }, { api_key = "x" })
      local _, e3 = c:run(Fly.viewer().id)
      t.eq(e3.message, "Fly HTTP 403: forbidden")
      c = client(Linear, { { status = 404, body = {} } }, { api_key = "x" })
      local _, e4 = c:run(Linear.viewer().id)
      t.eq(e4.message, "Linear HTTP 404 returned no GraphQL errors")
      local net =
        require("distilled.errors").new("TransportError", { message = "connection refused" })
      c = client(Linear, { net }, { api_key = "x", retry = "none" })
      local _, e5 = c:run(Linear.viewer().id)
      t.eq(e5.tag, "GraphQLTransportError")
      t.eq(e5.message, "Linear GraphQL HTTP request failed")
      t.eq(e5.cause, net)
    end
  )

  t.it("GitHub's top-level error type is the code (GitHubNotFound)", function()
    local c = client(GitHub, {
      {
        status = 200,
        body = {
          data = { repository = null },
          errors = {
            { type = "NOT_FOUND", path = { "repository" }, message = "Could not resolve" },
          },
        },
      },
    }, { token = "t" })
    local v, err = c:run(GitHub.repository({ owner = "o", name = "r" }).name)
    t.eq(v, nil)
    t.eq(err.tag, "GitHubNotFound")
    t.eq(err.code, "NOT_FOUND")
    t.truthy(err.categories.NotFoundError)
  end)

  t.it("secrets never reach an error message", function()
    local c = client(
      Linear,
      { { status = 500, body = "x" } },
      { api_key = "SECRET-KEY-1", retry = "none" }
    )
    local _, err = c:run(Linear.issue({ id = secret.wrap("SECRET-ARG") }).id)
    t.no_match(tostring(err), "SECRET", true)
    t.no_match(gql.describe(Linear.issue({ id = secret.wrap("SECRET-ARG") })), "SECRET", true)
  end)

  t.it("no transport is a ConfigError", function()
    local c = Linear.new({ api_key = "k" })
    local v, err = c:run(Linear.viewer().id)
    t.err(v, err, "ConfigError")
    t.eq(err.key, "transport")
  end)
end)

t.describe("graphql clients: pagination and spans", function()
  local function page(nodes, more, cursor)
    local edges = {}
    for i, n in ipairs(nodes) do
      edges[i] = { node = n }
    end
    return ok({
      teams = { edges = edges, pageInfo = { hasNextPage = more, endCursor = cursor or null } },
    })
  end

  t.it("client:items and client:pages walk a connection, one request per page", function()
    local c, host = client(
      Linear,
      { page({ { id = "a" } }, true, "c1"), page({ { id = "b" } }, false) },
      { api_key = "k" }
    )
    local ids = {}
    for id in
      c:items(gql.map(Linear.teams({ first = 1 }), function(team)
        return team.id
      end))
    do
      ids[#ids + 1] = id
    end
    t.same(ids, { "a", "b" })
    t.eq(#host.requests, 2)
    t.same(body_of(host.requests[2]).variables, { v0 = 1, v1 = "c1" })
    c = client(Linear, { page({ { id = "a" } }, false) }, { api_key = "k" })
    local pages = assert(c:pages(gql.map(Linear.teams({ first = 1 }), function(team)
      return { id = team.id }
    end)):collect())
    t.same(pages, { { { id = "a" } } })
  end)

  t.it("a document span: <prefix>.<root>, operation attributes, argument rules, headers", function()
    local memory = trace.exporters.memory()
    local c, host = client(Linear, {
      ok({ issue = { title = "t" } }, { ["x-request-id"] = "req-1" }),
    }, { api_key = "k", tracing = { level = "operation", exporter = memory } })
    assert(c:run(Linear.issue({ id = "ISS-9" }).title))
    t.eq(#memory.spans, 1)
    local span = memory.spans[1]
    t.eq(span.name, "Linear.issue")
    t.eq(span.attributes["graphql.operation.type"], "query")
    t.eq(span.attributes["graphql.operation.name"], "issue")
    t.eq(span.attributes["rpc.method"], "Linear/issue")
    t.eq(span.attributes["rpc.system.name"], "linear-api")
    t.eq(span.attributes["linear.issue_id"], "ISS-9")
    t.same(span.attributes["http.response.header.x-request-id"], { "req-1" })
    t.eq(span.attributes["http.response.status_code"], 200)
    t.match(host.requests[1].headers.traceparent, "^00%-" .. span.trace_id .. "%-")
  end)

  t.it("several roots name the span after the kind; a secret argument is no attribute", function()
    local memory = trace.exporters.memory()
    local c = client(Linear, {
      ok({ issue = { id = "1" }, viewer = { id = "2" } }),
    }, { api_key = "k", tracing = { level = "operation", exporter = memory } })
    assert(
      c:run({ a = Linear.issue({ id = secret.wrap("hidden-id") }).id, b = Linear.viewer().id })
    )
    local span = memory.spans[1]
    t.eq(span.name, "Linear.query")
    t.eq(span.attributes["graphql.operation.name"], nil)
    t.eq(span.attributes["linear.issue_id"], nil)
  end)

  t.it("a failed traced run carries the trace id and marks the span", function()
    local memory = trace.exporters.memory()
    local c = client(Linear, {
      {
        status = 200,
        body = { errors = { { message = "nope", extensions = { code = "AUTHENTICATION_ERROR" } } } },
      },
    }, { api_key = "k", tracing = { level = "operation", exporter = memory } })
    local v, err = c:run(Linear.viewer().id)
    t.err(v, err, "LinearAuthenticationError")
    t.eq(err.trace_id, memory.spans[1].trace_id)
    t.eq(memory.spans[1].status.code, "error")
  end)
end)
