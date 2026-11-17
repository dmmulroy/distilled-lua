-- distilled.protocol.grpc: requests (one protobuf frame, gRPC and gRPC-Web headers),
-- statuses from headers, HTTP trailers and gRPC-Web trailer frames, error mapping,
-- collected server streams, malformed replies, retries, and the same over real HTTP
-- against `dl serve` (curl transport) when DL_SERVE_URL is set (dl test --http).
-- Cases follow core/test/protocol-grpc.test.ts where it has them.
local t = require("spec.harness")
local json = require("distilled.json")
local errors = require("distilled.errors")
local S = require("distilled.schema")
local Client = require("distilled.client")
local grpc = require("distilled.protocol.grpc")
local pb = require("distilled.protobuf")
local secret = require("distilled.secret")
local testing = require("distilled.testing")

local D = {
  messages = {
    ["t.GetThingRequest"] = { { 1, "thingId", "string" }, { 2, "count", "int64" } },
    ["t.Thing"] = {
      { 1, "thingId", "string" },
      { 2, "size", "uint64" },
      { 3, "secretToken", "string" },
      { 4, "tags", "string", 0, 1 },
      { 5, "state", "enum", "t.State" },
      { 6, "ratio", "double" },
    },
  },
  enums = { ["t.State"] = { STATE_UNSPECIFIED = 0, READY = 1 } },
  methods = {
    ["/t.Things/GetThing"] = { "t.GetThingRequest", "t.Thing" },
    ["/t.Things/Watch"] = { "t.GetThingRequest", "t.Thing", 1 },
  },
}

local function m(spec)
  return S.member(spec)
end

local function service()
  local shapes = {}
  shapes.GetThingRequest = S.struct({
    name = "GetThingRequest",
    members = {
      m({ name = "thingId", schema = S.string, required = true }),
      m({ name = "count", schema = S.string }),
    },
  })
  shapes.Thing = S.struct({
    name = "Thing",
    members = {
      m({ name = "thingId", schema = S.string }),
      m({ name = "size", schema = S.string }),
      m({ name = "secretToken", schema = S.string, sensitive = true }),
      m({ name = "tags", schema = S.list(S.string) }),
      m({ name = "state", schema = S.enum({ "STATE_UNSPECIFIED", "READY" }) }),
      m({ name = "ratio", schema = S.number, nullable = true }),
    },
  })
  shapes.WatchRequest = S.struct({
    name = "WatchRequest",
    members = { m({ name = "thingId", schema = S.string }) },
  })
  shapes.WatchStream = S.struct({
    name = "WatchStream",
    members = { m({ name = "items", schema = S.list(S.ref("Thing")), required = true }) },
  })
  local classes = {
    ThingNotFound = errors.define({
      tag = "ThingNotFound",
      categories = { "NotFoundError" },
      matchers = { { code = 5 } },
    }),
  }
  return {
    name = "things",
    shapes = shapes,
    errors = classes,
    ops = {
      get_thing = {
        name = "GetThing",
        method = "POST",
        uri = "/t.Things/GetThing",
        code = 200,
        input = S.ref("GetThingRequest"),
        output = S.ref("Thing"),
        errors = { "ThingNotFound" },
      },
      watch = {
        name = "Watch",
        method = "POST",
        uri = "/t.Things/Watch",
        code = 200,
        input = S.ref("WatchRequest"),
        output = S.ref("WatchStream"),
        errors = {},
      },
      missing = {
        name = "Missing",
        method = "POST",
        uri = "/t.Things/Missing",
        code = 200,
        input = S.ref("WatchRequest"),
        errors = {},
      },
    },
  }
end

local function class(opts)
  opts = opts or {}
  return Client.define({
    service = service(),
    protocol = grpc.new({
      descriptors = D,
      web = opts.web,
      http2 = opts.http2,
      status_error = opts.status_error,
      base_url = function(creds)
        return creds.base_url
      end,
      headers = function(creds)
        return { authorization = "Bearer " .. tostring(secret.unwrap(creds.token)) }
      end,
      unknown_tag = "UnknownThingsError",
      parse_tag = "ThingsParseError",
    }),
    options = {
      token = { secret = true, required = true },
      base_url = { default = "https://things.test" },
    },
  })
end

-- a scripted transport that keeps `trailers` (testing.transport drops them)
local function scripted(responses)
  local tr = { requests = {} }
  return setmetatable(tr, {
    __call = function(self, req)
      self.requests[#self.requests + 1] = req
      local r = responses[#self.requests]
      if r == nil then
        error("scripted: no response for request #" .. #self.requests)
      end
      if errors.is(r) then
        return nil, r
      end
      return r
    end,
  })
end

local function client(responses, opts)
  local tr = scripted(responses)
  local host = testing.host({ transport = tr })
  local c = class(opts).new({ token = "tok", host = host, retry = (opts or {}).retry or "none" })
  return c, tr, host
end

local function thing_bytes(value)
  return assert(pb.encode(D, "t.Thing", value))
end

local function ok_reply(value, extra_headers, trailers)
  local headers = { ["content-type"] = "application/grpc" }
  for k, v in pairs(extra_headers or {}) do
    headers[k] = v
  end
  return {
    status = 200,
    headers = headers,
    body = pb.frame(thing_bytes(value)),
    trailers = trailers,
  }
end

local function status_reply(code, message, extra)
  local headers = { ["content-type"] = "application/grpc", ["grpc-status"] = tostring(code) }
  if message then
    headers["grpc-message"] = message
  end
  for k, v in pairs(extra or {}) do
    headers[k] = v
  end
  return { status = 200, headers = headers, body = "" }
end

t.describe("grpc request", function()
  t.it("sends one protobuf frame with gRPC headers at the method path", function()
    local c, tr = client({ ok_reply({ thingId = "a" }, { ["grpc-status"] = "0" }) })
    t.truthy(c:get_thing({ thingId = "a", count = "12" }))
    local req = tr.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://things.test/t.Things/GetThing")
    t.eq(req.headers["content-type"], "application/grpc")
    t.eq(req.headers["te"], "trailers")
    t.eq(req.headers["authorization"], "Bearer tok")
    t.eq(req.headers["accept"], nil)
    t.truthy(req.headers["user-agent"])
    t.eq(
      req.body,
      pb.frame(assert(pb.encode(D, "t.GetThingRequest", { thingId = "a", count = "12" })))
    )
    t.eq(req.http2, nil)
  end)

  t.it("sends gRPC-Web with web = true and asks for HTTP/2 with http2", function()
    local reply = ok_reply({ thingId = "a" })
    reply.headers["content-type"] = "application/grpc-web+proto"
    reply.body = reply.body .. pb.frame("grpc-status: 0\r\n", 128)
    local c, tr = client({ reply }, { web = true, http2 = true })
    t.truthy(c:get_thing({ thingId = "a" }))
    local req = tr.requests[1]
    t.eq(req.headers["content-type"], "application/grpc-web+proto")
    t.eq(req.headers["x-grpc-web"], "1")
    t.eq(req.headers["te"], nil)
    t.eq(req.http2, true)
  end)

  t.it("fails with InvalidInput when the value does not fit the descriptor", function()
    local c, tr = client({})
    local v, err = c:get_thing({ thingId = "a", count = "x" })
    t.fails_with("InvalidInput", v, err)
    t.eq(err.message, 't.GetThingRequest.count: expected an integer, got "x"')
    t.eq(err.member, "t.GetThingRequest")
    t.eq(#tr.requests, 0)
  end)

  t.it("fails with SdkError for an operation with no descriptor", function()
    local c = client({})
    t.fails_with("SdkError", c:missing({}))
  end)
end)

t.describe("grpc response", function()
  t.it("decodes a message through the output schema (defaults, sensitive members)", function()
    local c = client({
      ok_reply({ thingId = "a", size = "18446744073709551615", secretToken = "s3" }, nil, {
        ["grpc-status"] = "0",
      }),
    })
    local v = assert(c:get_thing({ thingId = "a" }))
    t.eq(v.thingId, "a")
    t.eq(v.size, "18446744073709551615")
    t.eq(v.state, "STATE_UNSPECIFIED")
    t.same(v.tags, {})
    t.truthy(secret.is(v.secretToken))
    t.eq(secret.unwrap(v.secretToken), "s3")
  end)

  t.it("treats a reply with a message and no status as OK (fetch reads no trailers)", function()
    local c = client({ ok_reply({ thingId = "b" }) })
    t.eq(assert(c:get_thing({ thingId = "b" })).thingId, "b")
  end)

  t.it("decodes NaN as null, as JSON.stringify does", function()
    local c = client({ ok_reply({ ratio = "NaN" }) })
    t.eq(assert(c:get_thing({ thingId = "b" })).ratio, json.null)
  end)

  t.it("maps a trailers-only status to the typed error by its gRPC code", function()
    local c = client({ status_reply(5, "thing%20not%20found") })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("ThingNotFound", v, err)
    t.eq(err.message, "thing not found")
    t.eq(err.code, 5)
    t.eq(err.status, 404)
    t.eq(err.body.status, "NOT_FOUND")
  end)

  t.it("maps codes no typed error matches by the HTTP status they stand for", function()
    local cases = {
      { 3, "BadRequest" },
      { 7, "Forbidden" },
      { 8, "TooManyRequests" },
      { 13, "InternalServerError" },
      { 14, "ServiceUnavailable" },
      { 16, "Unauthorized" },
      { 5, "NotFound" },
    }
    for _, c in ipairs(cases) do
      local cl = client({ status_reply(c[1]) })
      local v, err = cl:watch({ thingId = "a" })
      t.fails_with(c[2], v, err)
      t.eq(err.message, grpc.STATUS_NAMES[c[1]], c[2])
    end
  end)

  t.it("reads the status from HTTP trailers over the headers", function()
    local c = client({
      ok_reply({ thingId = "a" }, { ["grpc-status"] = "0" }, { ["grpc-status"] = "14" }),
    })
    t.fails_with("ServiceUnavailable", c:get_thing({ thingId = "a" }))
  end)

  t.it("fails INTERNAL when trailers came without a grpc-status", function()
    local c = client({ ok_reply({ thingId = "a" }, nil, { ["x-other"] = "1" }) })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err)
    t.eq(err.message, "server ended the call without a grpc-status")
  end)

  t.it("fails UNKNOWN for an empty reply without a status", function()
    local c =
      client({ { status = 200, headers = { ["content-type"] = "application/grpc" }, body = "" } })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err)
    t.eq(err.message, "gRPC response carried no message and no grpc-status")
    t.eq(err.body.code, 2)
  end)

  t.it("reads gRPC-Web trailer frames, and refuses a gRPC-Web reply without a status", function()
    local body = pb.frame(thing_bytes({ thingId = "w" }))
    local c = client({
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc-web+proto" },
        body = body .. pb.frame("grpc-status: 5\r\ngrpc-message: gone\r\n", 128),
      },
      { status = 200, headers = { ["content-type"] = "application/grpc-web+proto" }, body = body },
    }, { web = true })
    local v, err = c:get_thing({ thingId = "w" })
    t.fails_with("ThingNotFound", v, err)
    t.eq(err.message, "gone")
    v, err = c:get_thing({ thingId = "w" })
    t.fails_with("InternalServerError", v, err)
  end)

  t.it("collects a server stream into { items }", function()
    local body = pb.frame(thing_bytes({ thingId = "1" }))
      .. pb.frame(thing_bytes({ thingId = "2" }))
      .. pb.frame(thing_bytes({ thingId = "3" }))
    local c = client({
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc" },
        body = body,
        trailers = { ["grpc-status"] = "0" },
      },
      status_reply(0),
    })
    local v = assert(c:watch({ thingId = "x" }))
    t.eq(#v.items, 3)
    t.eq(v.items[3].thingId, "3")
    v = assert(c:watch({ thingId = "x" }))
    t.eq(#v.items, 0)
  end)

  t.it("refuses several messages for a unary method, and bad frames", function()
    local two = pb.frame(thing_bytes({})) .. pb.frame(thing_bytes({}))
    local c = client({
      { status = 200, headers = { ["content-type"] = "application/grpc" }, body = two },
      { status = 200, headers = { ["content-type"] = "application/grpc" }, body = "\1\0\0\0\0" },
      { status = 200, headers = { ["content-type"] = "application/grpc" }, body = "\0\0\0\0\9ab" },
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc" },
        body = pb.frame("\255\255"),
      },
    })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err) -- UNIMPLEMENTED: 501, an unmapped 5xx
    t.eq(err.message, "expected one response message, got 2")
    v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err)
    t.eq(err.message, "compressed gRPC frames are not supported")
    v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err)
    t.eq(err.message, "truncated gRPC frame")
    v, err = c:get_thing({ thingId = "a" })
    t.fails_with("ThingsParseError", v, err)
    t.match(err.message, "cannot decode the response of GetThing")
    t.eq(err.body, "<7 bytes of protobuf>")
  end)

  t.it("hands a non-gRPC HTTP failure to the REST decoder, or maps it with status_error", function()
    local c = client({
      { status = 503, headers = { ["content-type"] = "text/plain" }, body = "upstream down" },
      { status = 200, headers = { ["content-type"] = "text/html" }, body = "<html>" },
    })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("ServiceUnavailable", v, err)
    t.eq(err.message, "upstream down")
    v, err = c:get_thing({ thingId = "a" })
    t.fails_with("InternalServerError", v, err)
    t.eq(err.message, 'unexpected content-type "text/html"')

    local seen
    c = client({ { status = 429, headers = {}, body = "" }, status_reply(5) }, {
      status_error = function(info)
        seen = info
        return errors.new("SdkError", { message = "code " .. info.code })
      end,
    })
    v, err = c:get_thing({ thingId = "a" })
    t.fails_with("SdkError", v, err)
    t.eq(err.message, "code 14")
    t.eq(seen.message, "HTTP 429")
    -- a typed error still matches first
    t.fails_with("ThingNotFound", c:get_thing({ thingId = "a" }))
  end)

  t.it("decodes google.rpc.Status details from grpc-status-details-bin", function()
    local any_d = {
      messages = {
        ["google.rpc.Status"] = {
          { 1, "code", "int32" },
          { 2, "message", "string" },
          { 3, "details", "message", "google.protobuf.Any", 1 },
        },
      },
      enums = {},
      methods = {},
    }
    local bytes = assert(pb.encode(any_d, "google.rpc.Status", {
      code = 5,
      message = "x",
      details = { { ["@type"] = "type.googleapis.com/google.rpc.ErrorInfo", value = "CgFh" } },
    }))
    local b64 = require("distilled.crypto.base64").encode(bytes):gsub("=+$", "")
    local c = client({ status_reply(5, "x", { ["grpc-status-details-bin"] = b64 }) })
    local _, err = c:get_thing({ thingId = "a" })
    t.eq(err.body.details[1]["@type"], "type.googleapis.com/google.rpc.ErrorInfo")
    t.eq(err.body.details[1].value, "CgFh")
    t.same(grpc._details_of("!!"), {})
  end)

  t.it("percent-decodes grpc-message only when it is valid", function()
    t.eq(grpc._percent_decoded("a%20b"), "a b")
    t.eq(grpc._percent_decoded("100%"), "100%")
    t.eq(grpc._percent_decoded("%zz"), "%zz")
    t.eq(grpc._percent_decoded("%ff"), "%ff")
    t.eq(grpc._percent_decoded("caf%C3%A9"), "café")
  end)
end)

t.describe("grpc retries and transport failures", function()
  t.it("retries UNAVAILABLE and succeeds", function()
    local c, tr, host = client(
      { status_reply(14), status_reply(14), ok_reply({ thingId = "r" }) },
      {
        retry = { max_retries = 3 },
      }
    )
    t.eq(assert(c:get_thing({ thingId = "r" })).thingId, "r")
    t.eq(#tr.requests, 3)
    t.eq(#host.sleeps, 2)
  end)

  t.it("does not retry NOT_FOUND, and returns a transport error as is", function()
    local c, tr = client({
      status_reply(5),
      errors.new("TransportError", { message = "connection refused" }),
    }, { retry = { max_retries = 0 } })
    t.fails_with("ThingNotFound", c:get_thing({ thingId = "a" }))
    t.eq(#tr.requests, 1)
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("TransportError", v, err)
    t.eq(err.message, "connection refused")
  end)

  t.it("needs a transport", function()
    local c = class().new({ token = "x" })
    local v, err = c:get_thing({ thingId = "a" })
    t.fails_with("ConfigError", v, err)
  end)
end)

-- over real HTTP: dl serve scripts the reply bytes, curl carries them
local serve = require("verify.lib.serve")

local function http_host()
  local canary = require("verify.lib.canary")
  return canary.host()
end

t.describe("grpc over HTTP (dl serve)", function()
  if not serve.url() then
    t.pending("grpc over HTTP: DL_SERVE_URL is not set (run verify/dl test --http)")
    return
  end
  local b64 = require("distilled.crypto.base64")

  t.it("sends the frame byte for byte and reads statuses, errors and retries", function()
    local host = http_host()
    local s = serve.client(host.transport)
    s.reset()
    local reply = pb.frame(thing_bytes({ thingId = "h", size = "7" }))
    s.script("/t.Things/GetThing", {
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc", ["grpc-status"] = "14" },
      },
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc", ["grpc-status"] = "0" },
        body_b64 = b64.encode(reply),
      },
      {
        status = 200,
        headers = {
          ["content-type"] = "application/grpc",
          ["grpc-status"] = "5",
          ["grpc-message"] = "no%20such%20thing",
        },
      },
      { status = 503, body = "busy" },
    })
    local c = class().new({
      token = "tok",
      base_url = s.url(""),
      host = host,
      retry = { max_retries = 1, base_ms = 1 },
    })
    local v = assert(c:get_thing({ thingId = "h", count = "3" }))
    t.eq(v.thingId, "h")
    t.eq(v.size, "7")
    local reqs = s.requests()
    t.eq(#reqs, 2)
    t.eq(reqs[1].headers["content-type"], "application/grpc")
    t.eq(reqs[1].headers["te"], "trailers")
    local want = pb.frame(assert(pb.encode(D, "t.GetThingRequest", { thingId = "h", count = "3" })))
    t.eq(reqs[1].body_b64, b64.encode(want))
    local _, err = c:get_thing({ thingId = "h" })
    t.eq(err.tag, "ThingNotFound")
    t.eq(err.message, "no such thing")
    _, err = c:with({ retry = "none" }):get_thing({ thingId = "h" })
    t.eq(err.tag, "ServiceUnavailable")
  end)

  t.it("reads a gRPC-Web reply whose status is in its last frame", function()
    local host = http_host()
    local s = serve.client(host.transport)
    s.reset()
    local body = pb.frame(thing_bytes({ thingId = "web" })) .. pb.frame("grpc-status:0\r\n", 128)
    s.script("/t.Things/GetThing", {
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc-web+proto" },
        body_b64 = b64.encode(body),
      },
    })
    local c = class({ web = true }).new({ token = "tok", base_url = s.url(""), host = host })
    t.eq(assert(c:get_thing({ thingId = "x" })).thingId, "web")
    t.eq(s.requests()[1].headers["x-grpc-web"], "1")
  end)

  t.it("is a TransportError when the connection drops", function()
    local host = http_host()
    local s = serve.client(host.transport)
    s.reset()
    s.script("/t.Things/GetThing", { { drop = true } })
    local c = class().new({ token = "tok", base_url = s.url(""), host = host, retry = "none" })
    t.fails_with("TransportError", c:get_thing({ thingId = "x" }))
  end)
end)

---------------------------------------------------------------------------------------
-- distilled.protocol.rpc and the generated proto clients (clients/modal, boxd, e2b,
-- namespacelabs): the provider specs' settings, hosts, headers and error mapping
---------------------------------------------------------------------------------------
local rpc = require("distilled.protocol.rpc")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

-- a generated client over a scripted transport
local function gen_client(module, responses, opts, env)
  local tr = scripted(responses)
  local host = testing.host({ transport = tr, env = env or {} })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts or {}) do
    o[k] = v
  end
  return require(module).new(o), tr
end

local function json_reply(status, body, headers)
  local h = { ["content-type"] = "application/json" }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  return { status = status, headers = h, body = json.encode(body) }
end

t.describe("rpc settings", function()
  t.it("prepare: later environment variables, chained defaults, required checks", function()
    local settings = {
      region = { env = { "R" }, default = "us" },
      url = { env = { "U1", "U2" }, default = "https://{region}.x.test" },
      token = { secret = true, env = { "T1", "T2" }, required = true },
    }
    local prepare = rpc.prepare(settings)
    local s = assert(prepare({ token = "a" }, { getenv = function() end }))
    t.eq(s.url, "https://us.x.test")
    s = assert(prepare({ token = "a", region = "eu" }, { getenv = function() end }))
    t.eq(s.url, "https://eu.x.test")
    local env = { U2 = "https://second.test", T2 = "t2" }
    s = assert(prepare({}, {
      getenv = function(n)
        return env[n]
      end,
    }))
    t.eq(s.url, "https://second.test")
    t.eq(secret.unwrap(s.token), "t2")
    t.truthy(secret.is(s.token))
    local _, err = prepare({}, { getenv = function() end })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "token")
    t.match(err.message, "T1 or T2", true)
  end)

  t.it("prepare: require_one_of", function()
    local prepare = rpc.prepare({ a = { secret = true, env = "A" }, b = { secret = true } }, {
      require_one_of = { "a", "b" },
    })
    local _, err = prepare({}, { getenv = function() end })
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "one of the options a, b", true)
    t.truthy(prepare({ b = "x" }, {}))
  end)

  t.it("base_url: templates, prefixes and cases; host parts are checked", function()
    local by = rpc.base_url({
      by_prefix = { { "/a.", "{a_url}" } },
      when = "domain",
      cases = { ["e2b.app"] = "https://sandbox.{domain}" },
      default = "https://{port}-{id}.{domain}/",
    })
    t.eq(by({ a_url = "https://a.test/" }, { uri = "/a.S/M" }), "https://a.test")
    t.eq(by({ domain = "e2b.app" }, { uri = "/b.S/M" }), "https://sandbox.e2b.app")
    t.eq(by({ domain = "x.dev", port = "1", id = "sb" }, { uri = "/" }), "https://1-sb.x.dev")
    local _, err = by({ domain = "x.dev", port = "1", id = "a/b" }, { uri = "/" })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "id")
    _, err = by({ domain = "x.dev", port = "1" }, { uri = "/" })
    t.eq(err.key, "id")
  end)

  t.it("headers: unset and empty values are skipped, unless wins", function()
    local h = rpc.headers({
      { "authorization", "Bearer {bearer}" },
      { "x-id", "{id}", unless = "bearer" },
      { "x-fixed", "8" },
    })
    local out = h({ id = secret.wrap("i") })
    t.eq(out["x-id"], "i")
    t.eq(out["authorization"], nil)
    t.eq(out["x-fixed"], "8")
    out = h({ id = "i", bearer = "b" })
    t.eq(out["x-id"], nil)
    t.eq(out["authorization"], "Bearer b")
    t.eq(h({ id = "" })["x-id"], nil)
  end)
end)

t.describe("generated modal client (binary gRPC)", function()
  local function d()
    return require("modal.app.descriptors")
  end

  t.it("sends the token headers and decodes the reply", function()
    local reply = {
      status = 200,
      headers = { ["content-type"] = "application/grpc", ["grpc-status"] = "0" },
      body = pb.frame(assert(pb.encode(d(), "modal.client.AppGetOrCreateResponse", {
        appId = "ap-1",
      }))),
    }
    local c, tr = gen_client("modal.app", { reply }, nil, {
      MODAL_TOKEN_ID = "ak-1",
      MODAL_TOKEN_SECRET = "as-1",
      MODAL_API_URL = "http://modal.test",
    })
    local out = assert(c:app_get_or_create({
      appName = "x",
      objectCreationType = "OBJECT_CREATION_TYPE_CREATE_IF_MISSING",
    }))
    t.eq(out.appId, "ap-1")
    local req = tr.requests[1]
    t.eq(req.url, "http://modal.test/modal.client.ModalClient/AppGetOrCreate")
    t.eq(req.headers["x-modal-token-id"], "ak-1")
    t.eq(req.headers["x-modal-token-secret"], "as-1")
    t.eq(req.headers["x-modal-client-type"], "8")
    t.eq(req.headers["x-modal-client-version"], "1.6.3")
    t.eq(req.headers["content-type"], "application/grpc")
    t.eq(req.headers["authorization"], nil)
    t.eq(req.http2, nil)
    local sent = assert(pb.unframe(req.body)).messages[1]
    t.same(assert(pb.decode(d(), "modal.client.AppGetOrCreateRequest", sent)), {
      appName = "x",
      environmentName = "", -- proto3: a missing scalar decodes as its default
      objectCreationType = "OBJECT_CREATION_TYPE_CREATE_IF_MISSING",
    })
  end)

  t.it("maps a gRPC status to the model's error by code", function()
    local c = gen_client("modal.app", {
      {
        status = 200,
        headers = {
          ["content-type"] = "application/grpc",
          ["grpc-status"] = "5",
          ["grpc-message"] = "App%20not%20found",
        },
        body = "",
      },
    }, { token_id = "a", token_secret = "b" })
    local _, err = c:app_get_or_create({ appName = "x" })
    t.eq(err.tag, "AppNotFound")
    t.eq(err.code, 5)
    t.eq(err.message, "App not found")
  end)

  t.it("sends a bearer token instead of the token pair, over HTTP/2", function()
    local c, tr = gen_client("modal.app", {
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc", ["grpc-status"] = "0" },
        body = pb.frame(""),
      },
    }, { token_id = "a", token_secret = "b", bearer_token = "jwt", base_url = "https://r.test" })
    t.truthy(c:app_get_or_create({ appName = "x" }))
    local req = tr.requests[1]
    t.eq(req.headers["authorization"], "Bearer jwt")
    t.eq(req.headers["x-modal-token-id"], nil)
    t.eq(req.headers["x-modal-token-secret"], nil)
    t.eq(req.http2, true)
    t.eq(req.url, "https://r.test/modal.client.ModalClient/AppGetOrCreate")
  end)

  t.it("needs the token pair", function()
    local c, tr = gen_client("modal.app", {})
    local _, err = c:app_get_or_create({ appName = "x" })
    t.eq(err.tag, "ConfigError")
    t.eq(#tr.requests, 0)
  end)
end)

t.describe("generated boxd client (gRPC-Web)", function()
  t.it("collects a server stream and reads the token from BOXD_TOKEN", function()
    local d = require("boxd.descriptors")
    local body = pb.frame(assert(pb.encode(d, "boxd.api.v1.LogChunk", { data = "aGk=" })))
      .. pb.frame(assert(pb.encode(d, "boxd.api.v1.LogChunk", { data = "eW8=" })))
      .. pb.frame("grpc-status: 0\r\n", 128)
    local c, tr = gen_client("boxd", {
      { status = 200, headers = { ["content-type"] = "application/grpc-web+proto" }, body = body },
    }, nil, { BOXD_TOKEN = "bxd_1" })
    local out = assert(c:stream_logs({ vmId = "vm-1" }))
    t.eq(#out.items, 2)
    t.eq(out.items[1].data, "aGk=")
    t.eq(out.items[2].data, "eW8=")
    local req = tr.requests[1]
    t.eq(req.url, "https://boxd.sh:9443/boxd.api.v1.BoxdApi/StreamLogs")
    t.eq(req.headers["authorization"], "Bearer bxd_1")
    t.eq(req.headers["content-type"], "application/grpc-web+proto")
  end)

  t.it("an UNAUTHENTICATED trailer frame is Unauthorized", function()
    local c = gen_client("boxd", {
      {
        status = 200,
        headers = { ["content-type"] = "application/grpc-web+proto" },
        body = pb.frame("grpc-status: 16\r\ngrpc-message: bad key\r\n", 128),
      },
    }, { token = "x" })
    local _, err = c:get_vm({ vmId = "vm-1" })
    t.eq(err.tag, "Unauthorized")
    t.eq(err.message, "bad key")
  end)
end)

t.describe("generated e2b clients (REST and Connect JSON)", function()
  t.it("control plane: one of the API key and the access token", function()
    local c, tr = gen_client("e2b.sandboxes", {})
    local _, err = c:list_sandboxes({})
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "E2B_API_KEY", true)
    t.eq(#tr.requests, 0)
  end)

  t.it("control plane: the domain sets the API host; key and team headers", function()
    local c, tr = gen_client("e2b.sandboxes", { json_reply(200, {}) }, nil, {
      E2B_API_KEY = "e2b_k",
      E2B_DOMAIN = "e2b.dev",
    })
    t.truthy(c:list_sandboxes({}))
    local req = tr.requests[1]
    t.eq(string.match(req.url, "^[^?]*"), "https://api.e2b.dev/v2/sandboxes")
    t.eq(req.headers["x-api-key"], "e2b_k")
    t.eq(req.headers["authorization"], nil)
    t.eq(req.headers["x-team-id"], nil)
  end)

  t.it("envd: the shared sandbox host, routing headers and an empty JSON body", function()
    local c, tr = gen_client("e2b.process", { json_reply(200, { processes = {} }) }, {
      sandbox_id = "sb1",
      access_token = "envd-tok",
    }, { E2B_API_KEY = "never-sent" })
    t.truthy(c:list_processes({}))
    local req = tr.requests[1]
    t.eq(req.url, "https://sandbox.e2b.app/process.Process/List")
    t.eq(req.headers["e2b-sandbox-id"], "sb1")
    t.eq(req.headers["e2b-sandbox-port"], "49983")
    t.eq(req.headers["connect-protocol-version"], "1")
    t.eq(req.headers["x-access-token"], "envd-tok")
    t.eq(req.headers["x-api-key"], nil)
    t.eq(req.body, "{}")
  end)

  t.it("envd: another domain addresses <port>-<id>.<domain>; 502 is SandboxNotRunning", function()
    local c, tr = gen_client("e2b.process", {
      json_reply(502, { code = 502, message = "The sandbox was not found" }),
    }, { sandbox_id = "sb1", domain = "example.dev" })
    local _, err = c:list_processes({})
    t.eq(tr.requests[1].url, "https://49983-sb1.example.dev/process.Process/List")
    t.eq(err.tag, "SandboxNotRunning")
    t.eq(err.message, "The sandbox was not found")
  end)

  t.it("envd: needs the sandbox id", function()
    local c = gen_client("e2b.process", {})
    local _, err = c:list_processes({})
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "sandbox_id")
  end)

  t.it("volume content: the volume's token as the bearer", function()
    local c, tr = gen_client("e2b.volume_content", { json_reply(200, {}) }, { token = "vol-t" })
    t.truthy(c:list_volume_dir({ volumeID = "v1", path = "/" }))
    local req = tr.requests[1]
    t.eq(string.match(req.url, "^[^?]*"), "https://api.e2b.app/volumecontent/v1/dir")
    t.eq(req.headers["authorization"], "Bearer vol-t")
  end)

  t.it("a Connect error body under its status: string code, message", function()
    local c = gen_client("e2b.process", {
      json_reply(404, { code = "not_found", message = "process not found" }),
    }, { sandbox_id = "sb1" })
    local _, err = c:send_process_input({ process = { pid = 1 } })
    t.eq(err.tag, "NotFound")
    t.eq(err.message, "process not found")
  end)
end)

t.describe("generated namespacelabs clients (Connect JSON)", function()
  t.it("routes by proto package: compute by region, vault to the global host", function()
    local c, tr = gen_client("namespacelabs.compute", { json_reply(200, {}) }, nil, {
      NSC_TOKEN = "nsc",
      NSC_REGION = "eu",
    })
    t.truthy(c:create_instance({}))
    local req = tr.requests[1]
    t.eq(
      req.url,
      "https://eu.compute.namespaceapis.com/namespace.cloud.compute.v1beta.ComputeService/CreateInstance"
    )
    t.eq(req.headers["authorization"], "Bearer nsc")
    t.eq(req.body, "{}")
    local v, vtr = gen_client("namespacelabs.vault", { json_reply(200, {}) }, { token = "nsc" })
    t.truthy(v:list_objects({}))
    t.eq(
      vtr.requests[1].url,
      "https://global.namespaceapis.com/namespace.cloud.vault.v1beta.VaultService/ListObjects"
    )
  end)

  t.it("NSC_ENDPOINT is the compute host when NSC_COMPUTE_URL is unset", function()
    local c, tr = gen_client("namespacelabs.compute", { json_reply(200, {}) }, nil, {
      NSC_TOKEN = "nsc",
      NSC_ENDPOINT = "https://compute.local.test",
    })
    t.truthy(c:create_instance({}))
    t.eq(
      tr.requests[1].url,
      "https://compute.local.test/namespace.cloud.compute.v1beta.ComputeService/CreateInstance"
    )
  end)

  t.it("error matchers on the Connect code; the unknown error keeps details", function()
    local v = gen_client("namespacelabs.vault", {
      json_reply(400, { code = "invalid_argument", message = "bad name" }),
      json_reply(418, { code = "teapot", message = "short", details = { { type = "x" } } }),
    }, { token = "nsc" })
    local _, err = v:list_objects({})
    t.eq(err.tag, "InvalidArgument")
    t.eq(err.message, "bad name")
    _, err = v:list_objects({})
    t.eq(err.tag, "UnknownNamespaceLabsError")
    t.eq(err.code, "teapot")
    t.same(err.details, { { type = "x" } })
  end)
end)

---------------------------------------------------------------------------------------
-- the generator side (gen/proto.lua): provider spec proto, descriptors, failing early
---------------------------------------------------------------------------------------
local gen = require("distilled.gen")
local gen_model = require("distilled.gen.model")
local proto = require("distilled.gen.proto")

local TINY_DIR = t.root .. "/spec/golden/protobuf"

local function tiny_model(extra_ops, no_stream)
  local shapes = {
    ["t#Svc"] = {
      type = "service",
      version = "1",
      operations = { { target = "t#Get" }, { target = "t#Watch" } },
    },
    ["t#Get"] = {
      type = "operation",
      input = { target = "t#GetReq" },
      output = { target = "t#Thing" },
      traits = { ["smithy.api#http"] = { method = "POST", uri = "/t.Svc/Get", code = 200 } },
    },
    ["t#Watch"] = {
      type = "operation",
      input = { target = "t#WatchReq" },
      output = { target = "t#ThingStream" },
      traits = {
        ["smithy.api#http"] = { method = "POST", uri = "/t.Svc/Watch", code = 200 },
        ["com.distilled.grpc#serverStreaming"] = {},
      },
    },
    ["t#GetReq"] = {
      type = "structure",
      members = { id = { target = "smithy.api#String" } },
      traits = { ["smithy.api#input"] = {} },
    },
    ["t#WatchReq"] = {
      type = "structure",
      members = { id = { target = "smithy.api#String" } },
      traits = { ["smithy.api#input"] = {} },
    },
    ["t#GoneReq"] = {
      type = "structure",
      members = { id = { target = "smithy.api#String" } },
      traits = { ["smithy.api#input"] = {} },
    },
    ["t#Thing"] = {
      type = "structure",
      members = { id = { target = "smithy.api#String" } },
      traits = { ["smithy.api#output"] = {} },
    },
    ["t#ThingList"] = { type = "list", member = { target = "t#Thing" } },
    ["t#ThingStream"] = {
      type = "structure",
      members = { items = { target = "t#ThingList", traits = { ["smithy.api#required"] = {} } } },
      traits = { ["smithy.api#output"] = {} },
    },
  }
  if no_stream then
    shapes["t#Watch"].traits["com.distilled.grpc#serverStreaming"] = nil
  end
  for name, def in pairs(extra_ops or {}) do
    shapes[name] = def
    table.insert(shapes["t#Svc"].operations, { target = name })
  end
  return assert(
    gen_model.from_text(json.encode({ smithy = "2.0", shapes = shapes }), TINY_DIR .. "/tiny.json")
  )
end

local function tiny_spec(rpc_over)
  local r = { wire = "grpc", descriptors = "tiny_descriptors.ts" }
  for k, v in pairs(rpc_over or {}) do
    r[k] = v
  end
  return {
    name = "tiny",
    title = "Tiny",
    base_url = { default = "https://tiny.test", option = "base_url" },
    auth = { kind = "bearer", from = "token", env = "TINY_TOKEN" },
    unknown_tag = "UnknownTinyError",
    parse_tag = "TinyParseError",
    naming = { members = "wire" },
    proto = r,
  }
end

t.describe("gen.proto", function()
  t.it("parses descriptors.ts: single-quoted, double-quoted and plain JSON", function()
    local d =
      assert(proto.parse_descriptors('x = JSON.parse(\'{"messages":{},"methods":{}}\')', "a"))
    t.same(d, { messages = {}, methods = {}, enums = {} })
    d = assert(
      proto.parse_descriptors('JSON.parse("{\\"messages\\":{\\"a\\":[]},\\"methods\\":{}}")', "b")
    )
    t.same(d.messages, { a = {} })
    t.truthy(proto.parse_descriptors('{"messages":{},"methods":{},"enums":{}}', "c"))
    local _, err = proto.parse_descriptors("export const x = 1", "d.ts")
    t.match(err, "d.ts: no JSON.parse(", true)
    _, err = proto.parse_descriptors('{"messages":{}}', "e.json")
    t.match(err, "not a descriptor table", true)
  end)

  t.it("rejects a bad proto section before generating", function()
    local _, err = gen.generate({
      model = tiny_model(),
      provider = tiny_spec({ wire = "soap", headers = { { "x bad", "{no-name}" } }, colour = 1 }),
    })
    t.match(err, "proto.wire must be grpc, grpc-web or connect", true)
    t.match(err, "unknown key colour", true)
    t.match(err, "x bad is not a header name", true)
    t.match(err, "{no-name} is not an option name", true)
    _, err = gen.generate({ model = tiny_model(), provider = tiny_spec({ descriptors = false }) })
    t.match(err, "proto.descriptors must name the descriptors file", true)
    local both = tiny_spec()
    both.rpc = { protocol = "x.y", trait = "a.b#c", method = "POST", uri = "/" }
    _, err = gen.generate({ model = tiny_model(), provider = both })
    t.match(err, "rpc (task 22's) are not supported with proto", true)
  end)

  t.it("emits only the reachable descriptors, and a gRPC client module", function()
    local files = assert(gen.generate({ model = tiny_model(), provider = tiny_spec() }))
    local d = assert(require("distilled.compat").load(files["descriptors.lua"], "descriptors"))()
    t.same(d.methods, {
      ["/t.Svc/Get"] = { "t.GetReq", "t.Thing" },
      ["/t.Svc/Watch"] = { "t.GetReq", "t.Thing", 1 },
    })
    t.same(d.messages["t.Thing"][2], { 2, "state", "enum", "t.State" })
    t.truthy(d.messages["t.Child"])
    t.eq(d.messages["t.Unused"], nil)
    t.truthy(d.enums["t.State"])
    t.eq(d.enums["t.Other"], nil)
    t.match(files["init.lua"], 'require("distilled.protocol.grpc")', true)
    t.match(files["init.lua"], '{ "authorization", "Bearer {token}" }', true)
    t.match(files["README.md"], "Binary gRPC", true)
    t.eq(files["service.lua"]:find("unsupported", 1, true), nil)
  end)

  t.it("fails early on a method the descriptors lack or a streaming mismatch", function()
    local _, err = gen.generate({
      model = tiny_model({
        ["t#Gone"] = {
          type = "operation",
          input = { target = "t#GoneReq" },
          output = { target = "t#Thing" },
          traits = { ["smithy.api#http"] = { method = "POST", uri = "/t.Svc/Gone", code = 200 } },
        },
      }),
      provider = tiny_spec(),
    })
    t.match(err, "no gRPC method /t.Svc/Gone in", true)
    _, err = gen.generate({ model = tiny_model(nil, true), provider = tiny_spec() })
    t.match(err, "the descriptors say /t.Svc/Watch streams", true)
    _, err =
      gen.generate({ model = tiny_model(), provider = tiny_spec({ descriptors = "missing.ts" }) })
    t.match(err, "cannot read the gRPC descriptors", true)
  end)

  t.it("connect: no descriptors; a server stream stays unsupported", function()
    local spec = tiny_spec({ wire = "connect" })
    spec.proto.descriptors = nil
    local _, err = gen.generate({ model = tiny_model(), provider = spec })
    t.match(err, "streaming", true)
    spec.allow_unsupported = { "streaming" }
    local files = assert(gen.generate({ model = tiny_model(), provider = spec }))
    t.eq(files["descriptors.lua"], nil)
    t.match(files["init.lua"], 'require("distilled.protocol.connect")', true)
    t.match(files["init.lua"], "empty_json_body = false", true)
    t.match(files["service.lua"], 'unsupported = "streaming"', true)
  end)
end)

t.describe("curl config for gRPC requests", function()
  local common = require("distilled.transport.curl_common")

  t.it("data-binary is the last line (curl reads the body file when it parses it)", function()
    local text = common.config({
      method = "POST",
      url = "http://h.test/t.S/M",
      headers = { ["content-type"] = "application/grpc", te = "trailers" },
      body = "\0\0\0\0\0",
      timeout = 5,
      http2 = true,
    }, { body_path = "/dev/fd/3", follow_redirects = true })
    local last
    for line in string.gmatch(text, "[^\n]+") do
      last = line
    end
    t.eq(last, 'data-binary = "@/dev/fd/3"')
    t.eq(string.sub(text, -1), "\n")
    t.match(text, "\nhttp2-prior-knowledge\n", true)
    t.match(text, "%{size_header}", true)
  end)

  t.it("http2 must be a boolean; https asks for http2, not prior knowledge", function()
    local text =
      common.config({ method = "POST", url = "https://h.test/x", headers = {}, http2 = true })
    t.match(text, "\nhttp2\n", true)
    t.no_match(text, "prior-knowledge", true)
    local ok, err =
      common.check({ method = "POST", url = "https://h.test/x", headers = {}, http2 = "yes" })
    t.falsy(ok)
    t.eq(err.tag, "InvalidInput")
  end)
end)
