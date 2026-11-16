-- The REST protocol: request encoding through a call, success decoding, typed error
-- matching, status mapping and fallbacks. Ports protocol-rest.test.ts (names kept where
-- the case carries over; the "not ported" list is in tasks/04-runtime.done.md).
local t = require("spec.harness")
local rest = require("distilled.protocol.rest")
local Client = require("distilled.client")
local S = require("distilled.schema")
local errors = require("distilled.errors")
local json = require("distilled.json")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")
local trace = require("distilled.trace")
local expect = require("distilled.trace.expect")

local function must(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

local function m(spec)
  return S.member(spec)
end

local ThingInput = S.struct({
  name = "ThingInput",
  members = {
    m({ name = "id", bind = "label", schema = S.string, required = true }),
    m({ name = "limit", bind = "query", schema = S.number }),
    m({ name = "tags", wire = "tag", bind = "query", schema = S.list(S.string) }),
    m({
      name = "states",
      wire = "state",
      bind = "query",
      style = "comma",
      schema = S.list(S.string),
    }),
    m({ name = "trace", wire = "X-Trace-Id", bind = "header", schema = S.string }),
    m({ name = "displayName", wire = "display_name", schema = S.string }),
    m({ name = "secret", wire = "secret_value", schema = S.string, sensitive = true }),
  },
})

local ThingOutput = S.struct({
  name = "ThingOutput",
  members = {
    m({ name = "id", schema = S.string }),
    m({ name = "displayName", wire = "display_name", schema = S.string }),
    m({ name = "secret", wire = "secret_value", schema = S.string, sensitive = true }),
  },
})

local CLASSES = {
  ThingLocked = errors.define({
    tag = "ThingLocked",
    matchers = { { status = 409, message = { includes = "locked" } } },
  }),
  QuotaExceeded = errors.define({ tag = "QuotaExceeded", matchers = { { code = 4001 } } }),
  QuotaExceededOnCreate = errors.define({
    tag = "QuotaExceededOnCreate",
    matchers = { { code = 4001, status = 403 } },
  }),
  Teapot = errors.define({
    tag = "Teapot",
    matchers = { { status = 418, headers = { ["X-Reason"] = "teapot" } } },
  }),
  Gone = errors.define({ tag = "Gone", matchers = { { body = { ["/detail/kind"] = "gone" } } } }),
  Nested = errors.define({
    tag = "Nested",
    matchers = { { status = 412 } },
    fields = { "state", "details", "requestId" },
  }),
  SlowDown = errors.define({
    tag = "SlowDown",
    retryable = true,
    matchers = { { status = 409, body = { ["/code"] = "slow_down" } } },
    fields = { "retry_after" },
  }),
  KeyReused = errors.define({
    tag = "KeyReused",
    matchers = { { status = 422, body = { ["/code"] = "key_reused" } } },
    fields = { "requestId", "error" },
  }),
}
local WITH_ERRORS =
  { "ThingLocked", "QuotaExceeded", "QuotaExceededOnCreate", "Teapot", "Gone", "KeyReused" }

local function op(name, extra)
  local o = {
    name = name,
    method = "POST",
    uri = "/things/{id}",
    input = ThingInput,
    output = ThingOutput,
    errors = {},
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return o
end

local function service()
  return {
    name = "test",
    shapes = {},
    errors = CLASSES,
    ops = {
      create_thing = op("CreateThing"),
      create_thing_with_errors = op("CreateThingWithErrors", { errors = WITH_ERRORS }),
      plain = op("Plain", { errors = { "Nested", "SlowDown" } }),
      get_text = op("GetText", { method = "GET", uri = "/things/{id}/logs", output = S.string }),
      nullable = op("Nullable", {
        output = S.union({
          S.null,
          S.struct({
            name = "N",
            members = { m({ name = "id", schema = S.string, required = true }) },
          }),
        }),
      }),
      header_op = op("HeaderOp", {
        output = S.struct({
          name = "HeaderOutput",
          members = {
            m({ name = "id", schema = S.string }),
            m({
              name = "operation",
              wire = "Azure-AsyncOperation",
              bind = "header",
              schema = S.string,
            }),
            m({ name = "retry_after", wire = "Retry-After", bind = "header", schema = S.number }),
            m({ name = "code", bind = "status", schema = S.number }),
          },
        }),
      }),
      strict_op = op("StrictOp", {
        output = S.struct({
          name = "StrictOutput",
          members = { m({ name = "id", schema = S.string }) },
        }),
      }),
      list_op = op("ListOp", {
        output = S.list(
          S.struct({ name = "Item", members = { m({ name = "id", schema = S.string }) } })
        ),
        output_raw = true,
      }),
      binary_op = op("BinaryOp", { method = "GET", output = S.blob, output_raw = true }),
      page_op = op("PageOp", {
        output = S.struct({
          name = "PageOutput",
          members = {
            m({
              name = "items",
              bind = "payload",
              schema = S.list(
                S.struct({ name = "PI", members = { m({ name = "id", schema = S.string }) } })
              ),
            }),
            m({ name = "next_token", wire = "X-Next-Token", bind = "header", schema = S.string }),
          },
        }),
      }),
      no_output = op("NoOutput", { output = nil }),
    },
  }
end

local BASE = {
  base_url = function(creds)
    return "https://" .. creds.api_host
  end,
  headers = rest.bearer("token"),
  unknown_tag = "TestUnknownError",
  parse_tag = "TestParseError",
}

local function protocol_with(extra)
  local o = {}
  for k, v in pairs(BASE) do
    o[k] = v
  end
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return rest.new(o)
end

local DEFAULT = protocol_with()

local OPTIONS = {
  token = { secret = true, default = "tok-1" },
  api_host = { default = "api.test" },
}

-- client(responses, { protocol, client = options }) -> client, host
local function client(responses, opts)
  opts = opts or {}
  local Test =
    Client.define({ service = service(), protocol = opts.protocol or DEFAULT, options = OPTIONS })
  local host = testing.host({ responses = responses })
  local options = { host = host, retry = "none" }
  for k, v in pairs(opts.client or {}) do
    options[k] = v
  end
  return Test.new(options), host
end

local function json_response(body, status, headers)
  return { status = status or 200, headers = headers, body = body }
end

local function fail_on(response, method, opts)
  local c = client({ response }, opts)
  local v, err = c[method or "create_thing_with_errors"](c, { id = "t1" })
  t.eq(v, nil)
  return err
end

---------------------------------------------------------------------------------------

t.describe("rest: request encoding", function()
  t.it("builds path, query, header and JSON body members from the input schema", function()
    local c, host = client({ json_response({ id = "t1" }) })
    must(c:create_thing({
      id = "t1",
      limit = 5,
      tags = { "a", "b" },
      trace = "tr-1",
      displayName = "Widget",
    }))
    local r = host.requests[1]
    t.eq(r.method, "POST")
    t.eq(r.url, "https://api.test/things/t1?limit=5&tag=a&tag=b")
    t.eq(r.headers["x-trace-id"], "tr-1")
    t.eq(r.body, '{"display_name":"Widget"}')
    t.eq(r.headers["content-type"], "application/json")
  end)

  t.it("sends a comma-delimited query list as one parameter", function()
    local c, host = client({ json_response({}) })
    must(c:create_thing({ id = "t1", states = { "open", "closed" } }))
    t.eq(host.requests[1].url, "https://api.test/things/t1?state=open%2Cclosed")
  end)

  t.it("unwraps secret input values before serializing them", function()
    local c, host = client({ json_response({}) })
    must(c:create_thing({ id = "t1", secret = secret.wrap("s3cret") }))
    t.eq(host.requests[1].body, '{"secret_value":"s3cret"}')
  end)

  t.it(
    "applies the headers hook from the resolved credentials; adds accept and user-agent",
    function()
      local c, host = client({ json_response({}) }, { client = { token = "tok-2" } })
      must(c:create_thing({ id = "t1" }))
      local h = host.requests[1].headers
      t.eq(h.authorization, "Bearer tok-2")
      t.eq(h.accept, "application/json")
      t.eq(h["user-agent"], rest.USER_AGENT)
      t.eq(h.traceparent, nil)
    end
  )

  t.it("user_agent overrides the default", function()
    local c, host = client({ json_response({}) }, { client = { user_agent = "my-app/1" } })
    must(c:create_thing({ id = "t1" }))
    t.eq(host.requests[1].headers["user-agent"], "my-app/1")
  end)

  t.it("resolves credentials per call from the calling client", function()
    local c, host = client({ json_response({}), json_response({}) })
    must(c:create_thing({ id = "t1" }))
    must(c:with({ api_host = "other.test", token = "tok-9" }):create_thing({ id = "t1" }))
    t.eq(host.requests[1].url, "https://api.test/things/t1")
    t.eq(host.requests[2].url, "https://other.test/things/t1")
    t.eq(host.requests[2].headers.authorization, "Bearer tok-9")
  end)

  t.it("a credentials failure fails the call before any request is sent", function()
    local c, host = client({}, {
      client = {
        token = function()
          return nil, errors.new("Unauthorized", { message = "expired" })
        end,
      },
    })
    local err = t.fails_with("Unauthorized", c:create_thing({ id = "t1" }))
    t.eq(err.message, "expired")
    t.eq(#host.requests, 0)
  end)

  t.it("base_url receives the operation's route", function()
    local seen = {}
    local p = protocol_with({
      base_url = function(_, route)
        seen[#seen + 1] = route
        return "https://api.test"
      end,
    })
    local c = client({ json_response({}) }, { protocol = p })
    must(c:get_text({ id = "t1" }))
    t.same(seen, { { uri = "/things/{id}/logs", method = "GET" } })
  end)

  t.it("an error raised by base_url fails the call with that error", function()
    local refused = errors.new("ConfigError", { message = "scope missing", key = "scope" })
    local p = protocol_with({
      base_url = function()
        error(refused)
      end,
    })
    local c, host = client({}, { protocol = p })
    local _, err = c:create_thing({ id = "t1" })
    t.eq(err, refused)
    t.eq(#host.requests, 0)
    local p2 = protocol_with({
      base_url = function()
        error("boom")
      end,
    })
    t.fails_with("SdkError", client({}, { protocol = p2 }):create_thing({ id = "t1" }))
  end)

  t.it("map_member_header transforms member headers but not the auth headers", function()
    local p = protocol_with({
      map_member_header = function(name, value)
        return name == "x-trace-id" and ("mapped-" .. value) or value
      end,
    })
    local c, host = client({ json_response({}) }, { protocol = p })
    must(c:create_thing({ id = "t1", trace = "x" }))
    t.eq(host.requests[1].headers["x-trace-id"], "mapped-x")
    t.eq(host.requests[1].headers.authorization, "Bearer tok-1")
  end)

  t.it(
    "unknown_key_to_wire names input keys the schema does not model; without it they pass verbatim",
    function()
      local p = protocol_with({
        unknown_key_to_wire = function(k)
          return string.upper(k)
        end,
      })
      local c, host = client({ json_response({}) }, { protocol = p })
      must(c:create_thing({ id = "t1", extra_field = 1 }))
      t.eq(host.requests[1].body, '{"EXTRA_FIELD":1}')
      local c2, host2 = client({ json_response({}) })
      must(c2:create_thing({ id = "t1", extra_field = 1 }))
      t.eq(host2.requests[1].body, '{"extra_field":1}')
    end
  )

  t.it("a `..` label fails with InvalidInput and sends nothing", function()
    local c, host = client({})
    local err = t.fails_with("InvalidInput", c:create_thing_with_errors({ id = ".." }))
    t.eq(err.member, "id")
    t.eq(#host.requests, 0)
  end)

  t.it("the input table is never changed", function()
    local c = client({ json_response({}) })
    local input = { id = "t1", secret = secret.wrap("s"), tags = { "a" } }
    must(c:create_thing(input))
    t.truthy(secret.is(input.secret))
    t.same(input.tags, { "a" })
    t.eq(input.limit, nil)
  end)

  t.it("protocol.encode builds the request without sending", function()
    local req =
      must(DEFAULT.encode({ service = service() }, service().ops.create_thing, { id = "x" }, {
        token = "t",
        api_host = "h.test",
      }))
    t.eq(req.url, "https://h.test/things/x")
    t.eq(req.headers.authorization, "Bearer t")
  end)

  t.it("no transport is a ConfigError at call time", function()
    local Test = Client.define({ service = service(), protocol = DEFAULT, options = OPTIONS })
    local err =
      t.fails_with("ConfigError", Test.new({ retry = "none" }):create_thing({ id = "t1" }))
    t.eq(err.key, "transport")
  end)

  t.it(
    "a transport failure is returned as it is; a non-error failure becomes TransportError",
    function()
      local failure = errors.new("TransportError", { message = "connection refused" })
      local c = client({ failure })
      local _, err = c:create_thing({ id = "t1" })
      t.eq(err, failure)
      local c2 = client({
        function()
          return nil, "dns"
        end,
      })
      local e2 = t.fails_with("TransportError", c2:create_thing({ id = "t1" }))
      t.match(e2.message, "dns", true)
    end
  )
end)

-- task 09: a transport that breaks the contract says what was passed and what to pass
t.describe("rest: a transport that is not a transport", function()
  local function test_class()
    return Client.define({ service = service(), protocol = DEFAULT, options = OPTIONS })
  end

  t.it("a transport that returns a function (a constructor) is a ConfigError", function()
    local popen_curl = require("distilled.transport.popen_curl")
    -- popen_curl.new is the constructor as a plain function: calling it with the request
    -- returns a transport function instead of a response
    local c = test_class().new({ retry = "none", transport = popen_curl.new })
    local err = t.fails_with("ConfigError", c:create_thing({ id = "t1" }))
    t.eq(err.key, "transport")
    t.match(err.message, "returned a function", true)
    t.match(err.message, 'require("distilled.transport.popen_curl")()', true)
    t.match(err.message, 'require("distilled.transport.exec_curl")(exec)', true)
    t.match(err.message, 'host = require("distilled.host.popen")()', true)
  end)

  t.it("a transport that returns neither a response nor nil, err is a ConfigError", function()
    local results = {
      { "ok", "returned a string" },
      { 200, "returned a number" },
      { true, "returned a boolean" },
    }
    for _, case in ipairs(results) do
      local c = test_class().new({
        retry = "none",
        transport = function()
          return case[1]
        end,
      })
      local err = t.fails_with("ConfigError", c:create_thing({ id = "t1" }))
      t.eq(err.key, "transport")
      t.match(err.message, case[2], true)
    end
    local c = test_class().new({
      retry = "none",
      transport = function()
        return nil
      end,
    })
    local err = t.fails_with("ConfigError", c:create_thing({ id = "t1" }))
    t.match(err.message, "returned nothing", true)
  end)

  t.it("a contract failure is not retried", function()
    local n = 0
    local c = test_class().new({
      retry = { max_retries = 3 },
      sleep = function() end,
      transport = function()
        n = n + 1
        return function() end
      end,
    })
    t.fails_with("ConfigError", c:create_thing({ id = "t1" }))
    t.eq(n, 1)
  end)
end)

t.describe("rest: success decoding", function()
  t.it("maps wire keys to user names and wraps sensitive members as secrets", function()
    local c = client({
      json_response({ id = "t1", display_name = "Widget", secret_value = "s3cret", extra = 1 }),
    })
    local out = must(c:create_thing({ id = "t1" }))
    t.eq(out.id, "t1")
    t.eq(out.displayName, "Widget")
    t.eq(out.extra, 1)
    t.truthy(secret.is(out.secret))
    t.eq(secret.unwrap(out.secret), "s3cret")
    t.no_match(tostring(out.secret), "s3cret", true)
  end)

  t.it("a 204 with no body decodes to an empty object", function()
    local c = client({ { status = 204 } })
    local out = must(c:create_thing({ id = "t1" }))
    t.same(out, {})
    t.eq(json.encode(out), "{}")
  end)

  t.it("a whitespace-only 200 body decodes to an empty object", function()
    local c = client({ { status = 200, body = "  \n" } })
    t.same(must(c:create_thing({ id = "t1" })), {})
  end)

  t.it("a 200 response whose body is JSON null returns null, in strict mode too", function()
    local c = client({ { body = "null" }, { body = "null" } })
    t.eq(c:nullable({ id = "t1" }), json.null)
    t.eq(c:with({ validation = "strict" }):nullable({ id = "t1" }), json.null)
  end)

  t.it("an empty 200 body decodes to an empty string when the output is a string", function()
    local c = client({
      { status = 200, body = "", headers = { ["content-type"] = "text/plain" } },
      { status = 200, body = "done\n", headers = { ["content-type"] = "text/plain" } },
    })
    t.eq(c:get_text({ id = "t1" }), "")
    t.eq(c:get_text({ id = "t1" }), "done\n")
  end)

  t.it("transform_response runs on the parsed body before key mapping", function()
    local seen = {}
    local p = protocol_with({
      transform_response = function(body)
        seen[#seen + 1] = body
        return body.data
      end,
    })
    local c = client(
      { json_response({ data = { id = "t1", display_name = "Widget" } }) },
      { protocol = p }
    )
    local out = must(c:create_thing({ id = "t1" }))
    t.eq(#seen, 1)
    t.eq(seen[1].data.id, "t1")
    t.eq(out.displayName, "Widget")
  end)

  t.it("transform_response is not applied to error responses", function()
    local calls = { n = 0 }
    local p = protocol_with({
      transform_response = function(body)
        calls.n = calls.n + 1
        return body
      end,
    })
    fail_on(json_response({ message = "nope" }, 404), "create_thing", { protocol = p })
    t.eq(calls.n, 0)
  end)

  t.it("a transform_response that raises becomes an SdkError", function()
    local p = protocol_with({
      transform_response = function()
        error("bad transform")
      end,
    })
    local c = client({ json_response({}) }, { protocol = p })
    t.fails_with("SdkError", c:create_thing({ id = "t1" }))
  end)

  t.it(
    "response header members: copies declared headers, parsing number members; status members",
    function()
      local c = client({
        json_response({ id = "t1" }, 200, {
          ["Azure-AsyncOperation"] = "https://status.test/op/1",
          ["retry-after"] = "30",
          ["x-request-id"] = "ignored",
        }),
      }, { client = { validation = "strict" } })
      local out = must(c:header_op({ id = "t1" }))
      t.same(
        out,
        { id = "t1", operation = "https://status.test/op/1", retry_after = 30, code = 200 }
      )
    end
  )

  t.it("a bodiless 202 decodes to its headers", function()
    local c = client({
      { status = 202, headers = { ["azure-asyncoperation"] = "https://status.test/op/2" } },
    })
    t.same(must(c:header_op({ id = "t1" })), { operation = "https://status.test/op/2", code = 202 })
  end)

  t.it(
    "a number header member keeps text that is not a number, so strict mode reports it",
    function()
      local c = client(
        { json_response({}, 200, { ["retry-after"] = "Wed, 21 Oct 2026 07:28:00 GMT" }) },
        { client = { validation = "strict" } }
      )
      local err = t.fails_with("TestParseError", c:header_op({ id = "t1" }))
      t.eq(err.cause.path[1], "retry_after")
    end
  )

  t.it("strict validation failures become the parse error with the raw body", function()
    local c = client({ json_response({ id = 42 }) }, { client = { validation = "strict" } })
    local err = t.fails_with("TestParseError", c:strict_op({ id = "t1" }))
    t.same(err.body, { id = 42 })
    t.truthy(err.cause)
    t.truthy(err.categories.ParseError)
    t.eq(err.retryable, false)
  end)

  t.it(
    "additional mode allows unmodeled keys; strict refuses them; lenient checks nothing",
    function()
      local body = { id = "a", surprise = true }
      local c = client({ json_response(body), json_response(body), json_response({ id = 1 }) })
      must(c:with({ validation = "additional" }):strict_op({ id = "t1" }))
      t.fails_with("TestParseError", c:with({ validation = "strict" }):strict_op({ id = "t1" }))
      t.eq(must(c:strict_op({ id = "t1" })).id, 1)
    end
  )

  t.it("a parse_error hook builds the error", function()
    local p = protocol_with({
      parse_error = function(info)
        return errors.new("MyParse", { message = "custom", body = info.body })
      end,
    })
    local c = client(
      { json_response({ id = 42 }) },
      { protocol = p, client = { validation = "strict" } }
    )
    t.fails_with("MyParse", c:strict_op({ id = "t1" }))
  end)

  t.it("raw outputs return a bare array body (keys mapped)", function()
    local c = client({ json_response(json.array({ { id = "a" }, { id = "b" } })) })
    local out = must(c:list_op({ id = "t1" }))
    t.eq(#out, 2)
    t.eq(out[2].id, "b")
    t.truthy(json.is_array(out))
  end)

  t.it("binary outputs return the body bytes untouched", function()
    local bytes = string.char(0, 255, 1, 128, 10)
    local c = client({
      { status = 200, body = bytes, headers = { ["content-type"] = "application/octet-stream" } },
    })
    t.eq(c:binary_op({ id = "t1" }), bytes)
  end)

  t.it("an empty binary body is the empty string", function()
    local c = client({ { status = 200, body = "" } })
    t.eq(c:binary_op({ id = "t1" }), "")
  end)

  t.it("a bare array body lands in the payload member, next to header members", function()
    local c = client({
      json_response(
        json.array({ { id = "a" }, { id = "b" } }),
        200,
        { ["X-Next-Token"] = "page-2" }
      ),
    })
    local out = must(c:page_op({ id = "t1" }))
    t.eq(#out.items, 2)
    t.eq(out.next_token, "page-2")
  end)

  t.it("a missing header leaves the header member unset", function()
    local c = client({ json_response(json.array({})) })
    local out = must(c:page_op({ id = "t1" }))
    t.eq(#out.items, 0)
    t.eq(out.next_token, nil)
  end)

  t.it("an operation without an output returns the decoded body, or {} when empty", function()
    local c = client({ json_response({ a = 1 }), { status = 204 } })
    t.eq(must(c:no_output({ id = "t1" })).a, 1)
    t.same(must(c:no_output({ id = "t1" })), {})
  end)

  t.it("a non-JSON body is returned as text in lenient mode", function()
    local c = client({ { body = "<html>ok</html>" } })
    t.eq(c:strict_op({ id = "t1" }), "<html>ok</html>")
  end)
end)

t.describe("rest: outputs that can hold a secret", function()
  local CANARY = "sk-CANARY-rest-77"

  t.it("a non-JSON body fails in every mode, and the error withholds the body", function()
    for _, mode in ipairs({ "lenient", "additional", "strict" }) do
      local c = client({ { body = "key=" .. CANARY } }, { client = { validation = mode } })
      local err = t.fails_with("TestParseError", c:create_thing({ id = "t1" }))
      t.eq(err.body, "[REDACTED]")
      t.eq(err.cause, "Invalid JSON response")
      t.no_match(tostring(err), CANARY, true)
    end
  end)

  t.it("a mismatch in strict mode withholds the body and the value found", function()
    local c = client(
      { json_response({ secret_value = 42, other = CANARY }) },
      { client = { validation = "strict" } }
    )
    local err = t.fails_with("TestParseError", c:create_thing({ id = "t1" }))
    t.eq(err.body, "[REDACTED]")
    t.eq(err.cause.actual, "[REDACTED]")
    t.no_match(json.encode({ m = err.message, c = err.cause.message }), CANARY, true)
  end)

  t.it("a sensitive output member is a secret through a fixture call (create_api_key)", function()
    local Neon = Client.define({
      service = fixtures.service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local host = testing.host({ responses = { { body = fixtures.bodies.api_key(CANARY) } } })
    local out = must(Neon.new({ host = host }):create_api_key({ key_name = "ci" }))
    t.truthy(secret.is(out.key))
    t.eq(secret.unwrap(out.key), CANARY)
    t.eq(out.name, "ci")
  end)
end)

t.describe("rest: typed error matching", function()
  t.it(
    "a declared error whose status and message matcher match wins over the status map",
    function()
      local err = fail_on(json_response({ message = "thing is locked" }, 409))
      t.eq(err.tag, "ThingLocked")
      t.eq(err.message, "thing is locked")
    end
  )

  t.it("a numeric envelope code selects the declared error with that code", function()
    local err = fail_on(json_response({ code = 4001, message = "quota" }, 400))
    t.eq(err.tag, "QuotaExceeded")
    t.eq(err.message, "quota")
    t.eq(err.code, 4001)
  end)

  t.it("the most specific matching declared error wins", function()
    t.eq(
      fail_on(json_response({ code = 4001, message = "quota" }, 403)).tag,
      "QuotaExceededOnCreate"
    )
  end)

  t.it("a string envelope code never satisfies a numeric code matcher", function()
    local err = fail_on(json_response({ code = "4001", message = "quota" }, 400))
    t.eq(err.tag, "BadRequest")
    t.eq(err.code, "4001")
  end)

  t.it(
    "header matchers see the response headers case-insensitively, with body and headers on the error",
    function()
      local err =
        fail_on(json_response({ message = "short and stout" }, 418, { ["x-reason"] = "teapot" }))
      t.eq(err.tag, "Teapot")
      t.same(err.body, { message = "short and stout" })
      t.eq(err.headers["x-reason"], "teapot")
    end
  )

  t.it("body pointer matchers see the parsed JSON body", function()
    t.eq(fail_on(json_response({ message = "bye", detail = { kind = "gone" } }, 410)).tag, "Gone")
  end)

  t.it(
    "a matched error's declared fields carry the body's values, with the matched message",
    function()
      local err = fail_on(json_response({
        code = "key_reused",
        message = "key was used",
        requestId = "req_1",
        error = { details = { window = "day" } },
        extra = true,
      }, 422))
      t.eq(err.tag, "KeyReused")
      t.eq(err.requestId, "req_1")
      t.same(err.error, { details = { window = "day" } })
      -- Distilled reports 0 for a string code; here the wire code is kept (STATUS.md 01)
      t.eq(err.code, "key_reused")
      t.eq(err.message, "key was used")
      t.eq(err.extra, nil)
    end
  )

  t.it("declared errors are ignored when nothing matches", function()
    local err = fail_on(json_response({ message = "thing is busy" }, 409))
    t.eq(err.tag, "Conflict")
    t.eq(err.message, "thing is busy")
  end)

  t.it("operations without declared errors fall straight to the status map", function()
    t.eq(
      fail_on(json_response({ message = "thing is locked" }, 409), "create_thing").tag,
      "Conflict"
    )
  end)

  t.it("a regex matcher picks the class through a whole call (fixtures create_project)", function()
    local Neon = Client.define({
      service = fixtures.service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL }),
    })
    local host = testing.host({
      responses = {
        { status = 423, body = { message = "project p1 is locked by op-7", request_id = "r-1" } },
        { status = 423, body = { message = "branch is locked" } },
      },
    })
    local c = Neon.new({ host = host, retry = "none" })
    local err = t.fails_with("ProjectLocked", c:create_project({ project = { name = "x" } }))
    t.eq(err.request_id, "r-1")
    t.truthy(err.retryable)
    t.fails_with("Locked", c:create_project({ project = { name = "x" } }))
  end)
end)

t.describe("rest: error response fields", function()
  t.it("a status-mapped error carries the body and headers", function()
    local err = fail_on(
      json_response({ message = "busy", requestId = "req_7" }, 409, { ["x-request-id"] = "req_7" }),
      "plain"
    )
    t.eq(err.tag, "Conflict")
    t.same(err.body, { message = "busy", requestId = "req_7" })
    t.eq(err.headers["x-request-id"], "req_7")
    t.eq(err.status, 409)
  end)

  t.it(
    "error_fields_at reads declared fields from the nested object, then the top level",
    function()
      local p = protocol_with({ error_fields_at = "/error" })
      local err = fail_on(
        json_response({
          error = { message = "no", state = "FAILED_PRECONDITION", details = { 1 } },
          requestId = "r",
        }, 412),
        "plain",
        { protocol = p }
      )
      t.eq(err.tag, "Nested")
      t.eq(err.state, "FAILED_PRECONDITION")
      t.same(err.details, { 1 })
      t.eq(err.requestId, "r")
    end
  )

  t.it("a typed error that declares retry_after gets the Retry-After hint", function()
    local err = fail_on(
      json_response({ code = "slow_down", message = "later" }, 409, { ["retry-after"] = "7" }),
      "plain"
    )
    t.eq(err.tag, "SlowDown")
    t.eq(err.retry_after, 7)
  end)
end)

t.describe("rest: status mapping and fallbacks", function()
  t.it("mapped 4xx statuses become core HTTP errors with the envelope message", function()
    local err = fail_on(json_response({ message = "no such thing" }, 404))
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "no such thing")
  end)

  t.it("the default envelope falls back to a string `error` field for the message", function()
    local err = fail_on(json_response({ error = "bad input" }, 400))
    t.eq(err.tag, "BadRequest")
    t.eq(err.message, "bad input")
  end)

  t.it("a JSON body without a message yields an `HTTP <status>` message", function()
    t.eq(fail_on(json_response({ detail = "x" }, 400)).message, "HTTP 400")
  end)

  t.it("retryable statuses carry retry_after from Retry-After and from RateLimit", function()
    local e1 = fail_on(json_response({ message = "slow down" }, 429, { ["retry-after"] = "7" }))
    t.eq(e1.tag, "TooManyRequests")
    t.eq(e1.retry_after, 7)
    local e2 = fail_on(json_response({}, 503, { ratelimit = "r=0, t=12" }))
    t.eq(e2.tag, "ServiceUnavailable")
    t.eq(e2.retry_after, 12)
  end)

  t.it("non-retryable statuses never carry retry_after", function()
    local err = fail_on(json_response({ message = "gone" }, 404, { ["retry-after"] = "7" }))
    t.eq(err.tag, "NotFound")
    t.eq(err.retry_after, nil)
  end)

  t.it("unmapped 5xx statuses become a retryable InternalServerError", function()
    local err = fail_on(json_response({ message = "origin down" }, 521, { ["retry-after"] = "3" }))
    t.eq(err.tag, "InternalServerError")
    t.eq(err.message, "origin down")
    t.truthy(err.retryable)
    -- 521 is not a retryable status, so its hint is not stamped
    t.eq(err.retry_after, nil)
  end)

  t.it(
    "unmapped 4xx statuses become the unknown error with the wire details, never retryable",
    function()
      local err =
        fail_on(json_response({ code = "PAYMENT", message = "pay up" }, 402, { ["x-id"] = "r1" }))
      t.eq(err.tag, "TestUnknownError")
      t.eq(err.status, 402)
      t.eq(err.code, "PAYMENT")
      t.eq(err.message, "pay up")
      t.same(err.body, { code = "PAYMENT", message = "pay up" })
      t.eq(err.headers["x-id"], "r1")
      t.eq(err.retryable, false)
      t.falsy(errors.is_transient(err))
    end
  )

  t.it("an unknown_error hook builds the fallback", function()
    local p = protocol_with({
      unknown_error = function(info)
        return errors.new("Hooked", { message = info.message, status = info.status })
      end,
    })
    t.eq(
      fail_on(json_response({ message = "x" }, 402), "create_thing", { protocol = p }).tag,
      "Hooked"
    )
  end)

  t.it("a non-JSON error body becomes the trimmed message and the raw body", function()
    local err = fail_on({ status = 402, body = "  <html>Bad gateway thing</html>\n" })
    t.eq(err.message, "<html>Bad gateway thing</html>")
    t.eq(err.body, "  <html>Bad gateway thing</html>\n")
    t.eq(err.code, nil)
  end)

  t.it("a non-JSON error body can still be matched by a declared message matcher", function()
    local err = fail_on({ status = 409, body = "resource locked by another op" })
    t.eq(err.tag, "ThingLocked")
    t.eq(err.message, "resource locked by another op")
  end)

  t.it("a non-JSON mapped error keeps the text as the message", function()
    local err = fail_on({ status = 503, body = "Service Unavailable" })
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(err.message, "Service Unavailable")
  end)

  t.it("an empty error body yields an `HTTP <status>` message", function()
    local err = fail_on({ status = 402 })
    t.eq(err.message, "HTTP 402")
    t.eq(err.body, nil)
  end)
end)

t.describe("rest: error_envelope, status_map and classify_error options", function()
  local Custom = errors.define({ tag = "CustomNotFound", fields = { "retry_after" } })
  local custom = protocol_with({
    error_envelope = function(body)
      local e = type(body) == "table" and body.err
      if e then
        return { code = e.id, message = e.text }
      end
      return nil
    end,
    status_map = { [404] = Custom },
  })
  local function custom_fail(response)
    local c = client({ response }, { protocol = custom })
    local _, err = c:create_thing_with_errors({ id = "t1" })
    return err
  end

  t.it("a custom error_envelope supplies the code and message used for matching", function()
    local err = custom_fail(json_response({ err = { id = 4001, text = "quota" } }, 400))
    t.eq(err.tag, "QuotaExceeded")
    t.eq(err.message, "quota")
  end)

  t.it("a custom error_envelope returning nil falls back to `HTTP <status>`", function()
    local err = custom_fail(json_response({ message = "ignored" }, 404))
    t.eq(err.tag, "CustomNotFound")
    t.eq(err.message, "HTTP 404")
  end)

  t.it("a custom status_map replaces the default map rather than extending it", function()
    local err = custom_fail(json_response({ err = { text = "bad" } }, 400))
    t.eq(err.tag, "TestUnknownError")
    t.eq(err.message, "bad")
  end)

  t.it("unmapped 5xx still become InternalServerError with a custom status_map", function()
    local err = custom_fail(json_response({ err = { text = "boom" } }, 500))
    t.eq(err.tag, "InternalServerError")
    t.eq(err.message, "boom")
  end)

  t.it("an error_envelope that raises becomes an SdkError", function()
    local p = protocol_with({
      error_envelope = function()
        error("envelope bug")
      end,
    })
    local err = fail_on(json_response({}, 400), "create_thing", { protocol = p })
    t.eq(err.tag, "SdkError")
    t.match(err.message, "envelope bug", true)
  end)

  t.it("classify_error is consulted first and sees the wire details", function()
    local seen = {}
    local p = protocol_with({
      classify_error = function(info)
        seen[#seen + 1] = info
        if info.status == 403 and info.headers["x-ratelimit-remaining"] == "0" then
          return errors.new("TooManyRequests", { message = info.message, status = 403 })
        end
        return nil
      end,
    })
    local err = fail_on(
      json_response({ message = "slow" }, 403, { ["x-ratelimit-remaining"] = "0" }),
      "create_thing_with_errors",
      { protocol = p }
    )
    t.eq(err.tag, "TooManyRequests")
    t.eq(seen[1].message, "slow")
    t.same(seen[1].body, { message = "slow" })
    t.eq(
      fail_on(json_response({ message = "nope" }, 403), "create_thing", { protocol = p }).tag,
      "Forbidden"
    )
  end)

  t.it("a classify_error that raises, or returns a non-error, becomes an SdkError", function()
    local p = protocol_with({
      classify_error = function()
        error("classify bug")
      end,
    })
    t.eq(fail_on(json_response({}, 400), "create_thing", { protocol = p }).tag, "SdkError")
    local p2 = protocol_with({
      classify_error = function()
        return "nope"
      end,
    })
    t.eq(fail_on(json_response({}, 400), "create_thing", { protocol = p2 }).tag, "SdkError")
  end)
end)

t.describe("rest: tracing", function()
  t.it("a recording tracer adds traceparent and annotates the operation span", function()
    local memory = trace.exporters.memory()
    local host = testing.host({ responses = { json_response({ id = "t1" }, 200) } })
    local tracer = trace.new({ level = "operation", exporter = memory, host = host })
    local Test = Client.define({ service = service(), protocol = DEFAULT, options = OPTIONS })
    local c = Test.new({ host = host, tracer = tracer })
    must(c:create_thing({ id = "t1" }))
    local tp = host.requests[1].headers.traceparent
    t.match(tp, "^00%-%x+%-%x+%-01$")
    local s = expect(memory.spans):span("CreateThing")
    s:attr("http.request.method", "POST")
      :attr("server.address", "api.test")
      :attr("server.port", 443)
      :attr("http.response.status_code", 200)
    t.eq(memory.spans[1].trace_id, string.match(tp, "^00%-(%x+)%-"))
  end)

  t.it("a failed call's error carries the trace id; tostring shows it", function()
    local memory = trace.exporters.memory()
    local host = testing.host({ responses = { json_response({ message = "no" }, 404) } })
    local tracer = trace.new({ level = "operation", exporter = memory, host = host })
    local Test = Client.define({ service = service(), protocol = DEFAULT, options = OPTIONS })
    local _, err = Test.new({ host = host, tracer = tracer }):create_thing({ id = "t1" })
    t.eq(err.trace_id, memory.spans[1].trace_id)
    t.match(tostring(err), "[trace " .. err.trace_id .. "]", true)
    expect(memory.spans):span("CreateThing"):failed("NotFound"):attr("error.type", "NotFound")
  end)

  t.it("telemetry.propagate = false keeps traceparent off the request", function()
    local svc = service()
    svc.telemetry = { propagate = false }
    local host = testing.host({ responses = { json_response({}) } })
    local tracer =
      trace.new({ level = "operation", exporter = trace.exporters.memory(), host = host })
    local Test = Client.define({ service = svc, protocol = DEFAULT, options = OPTIONS })
    must(Test.new({ host = host, tracer = tracer }):create_thing({ id = "t1" }))
    t.eq(host.requests[1].headers.traceparent, nil)
  end)
end)

t.describe("rest: helpers and misuse", function()
  t.it("bearer and header read an option and unwrap a secret", function()
    t.same(rest.bearer("k")({ k = secret.wrap("v") }), { authorization = "Bearer v" })
    t.same(rest.bearer("k")({}), {})
    t.same(rest.header("X-Api-Key", "k")({ k = "v" }), { ["x-api-key"] = "v" })
  end)

  t.it("rest.new refuses a missing base_url and a non-function headers", function()
    t.raises(function()
      rest.new({})
    end, "base_url")
    t.raises(function()
      rest.new({ base_url = "x", headers = {} })
    end, "headers")
  end)

  t.it("the default envelope", function()
    t.same(rest.default_error_envelope({ code = 3, message = "m" }), { code = 3, message = "m" })
    t.same(rest.default_error_envelope({ code = {}, error = "e" }), { message = "e" })
    t.eq(rest.default_error_envelope(json.array({})), nil)
    t.eq(rest.default_error_envelope("x"), nil)
  end)
end)
