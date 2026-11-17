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
