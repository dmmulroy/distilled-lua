-- The OTLP/HTTP exporter: offline over a recording transport, then against dl serve
-- (DL_SERVE_URL, set by verify/dl test --http) with the real curl transport.
local t = require("spec.harness")
local otlp_http = require("distilled.trace.otlp_http")
local otlp = require("distilled.trace.otlp")
local trace = require("distilled.trace")
local json = require("distilled.json")
local secret = require("distilled.secret")
local serve = require("verify.lib.serve")
local fake_host = require("verify.lib.trace_fake_host")

local REX = rawget(_G, "rex")
local SECRET = "sk-CANARY-otlp-0123456789"

local function recording(response, err)
  local requests = {}
  local tr = function(req)
    requests[#requests + 1] = req
    if type(response) == "function" then
      return response(req)
    end
    return response, err
  end
  return tr, requests
end

-- two finished spans from a real tracer, so the exporter sees the documented shape
local function sample_spans()
  local mem = trace.exporters.memory()
  local tracer =
    trace.new({ level = "debug", exporter = mem, host = fake_host.new(), service_name = "svc" })
  tracer:with("Outer", { kind = "client", attributes = { a = 1 } }, function()
    tracer:with("inner", {}, function() end)
  end)
  tracer:flush()
  return mem.spans
end

t.describe("otlp_http (offline)", function()
  t.it("POSTs OTLP/JSON to <endpoint>/v1/traces", function()
    local tr, requests = recording({ status = 200, headers = {}, body = "{}" })
    local exp = otlp_http({ endpoint = "http://collector.test:4318/", transport = tr, timeout = 2 })
    t.truthy(exp(sample_spans(), { service_name = "svc" }))
    t.eq(#requests, 1)
    local req = requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "http://collector.test:4318/v1/traces")
    t.eq(req.headers["content-type"], "application/json")
    t.eq(req.timeout, 2)
    local spans = otlp.decode(json.decode(req.body))
    t.eq(#spans, 2)
    t.eq(spans[1].name, "Outer")
    t.match(req.body, '"service.name"', true)
    t.match(req.body, '"stringValue":"svc"', true)
  end)

  t.it("keeps an endpoint that already ends in /v1/traces", function()
    local tr, requests = recording({ status = 200, headers = {}, body = "" })
    otlp_http({ endpoint = "https://c.test/v1/traces", transport = tr })(sample_spans())
    t.eq(requests[1].url, "https://c.test/v1/traces")
  end)

  t.it("sends no request for an empty batch", function()
    local tr, requests = recording({ status = 200, headers = {}, body = "" })
    t.truthy(otlp_http({ endpoint = "http://c.test", transport = tr })({}))
    t.eq(#requests, 0)
  end)

  t.it("unwraps secret headers but never names them in errors", function()
    local tr, requests =
      recording(nil, require("distilled.errors").new("TransportError", { message = "refused" }))
    local exp = otlp_http({
      endpoint = "http://user:pw@c.test/?token=" .. SECRET,
      transport = tr,
      headers = { Authorization = secret.wrap("Bearer " .. SECRET) },
    })
    local ok, err = exp(sample_spans())
    t.falsy(ok)
    t.eq(err.tag, "SdkError")
    t.eq(requests[1].headers.authorization, "Bearer " .. SECRET)
    t.match(err.message, "refused", true)
    t.no_match(err.message, SECRET, true)
    t.no_match(err.message, "pw", true)
  end)

  t.it("returns (does not raise) an SdkError on a non-2xx answer", function()
    local tr = recording({ status = 400, headers = {}, body = '{"message":"bad"}' })
    local ok, err = otlp_http({ endpoint = "http://c.test", transport = tr })(sample_spans())
    t.falsy(ok)
    t.eq(err.tag, "SdkError")
    t.eq(err.status, 400)
    t.match(err.message, "HTTP 400", true)
  end)

  t.it("treats partialSuccess.rejectedSpans > 0 as a failure", function()
    local body = '{"partialSuccess":{"rejectedSpans":"1","errorMessage":"too old"}}'
    local tr = recording({ status = 200, headers = {}, body = body })
    local ok, err = otlp_http({ endpoint = "http://c.test", transport = tr })(sample_spans())
    t.falsy(ok)
    t.match(err.message, "rejected 1 of 2", true)
    local tr2 = recording({ status = 200, headers = {}, body = '{"partialSuccess":{}}' })
    t.truthy(otlp_http({ endpoint = "http://c.test", transport = tr2 })(sample_spans()))
  end)

  t.it(
    "is untraced: exporting from a tracer adds no spans, and failures come back from flush",
    function()
      local mem = trace.exporters.memory()
      local calls = 0
      local tr = function(req)
        calls = calls + 1
        return { status = 503, headers = {}, body = "down" }
      end
      local tracer = trace.new({
        level = "debug",
        host = fake_host.new(),
        exporter = {
          mem,
          trace.exporters.otlp_http({ endpoint = "http://c.test", transport = tr }),
        },
      })
      tracer:with("Op", {}, function() end)
      local ok, err = tracer:flush()
      t.falsy(ok)
      t.eq(err.tag, "SdkError")
      t.match(err.message, "trace export failed", true)
      t.match(err.message, "HTTP 503", true)
      t.eq(calls, 1)
      t.eq(#mem.spans, 1)
      t.truthy(tracer:flush()) -- nothing new was recorded by the export itself
      t.eq(calls, 1)
    end
  )

  t.it("misuse raises", function()
    t.raises(function()
      otlp_http({})
    end, "endpoint")
    t.raises(function()
      otlp_http({ endpoint = "http://c", transport = "curl" })
    end, "transport")
    -- task 09: a transport module (a constructor) is refused, with what to pass instead
    t.raises(function()
      otlp_http({ endpoint = "http://c", transport = require("distilled.transport.exec_curl") })
    end, "transport is the distilled.transport.exec_curl module")
  end)
end)

local BASE = serve.url()
if not BASE then
  t.describe("otlp_http over HTTP", function()
    t.pending("skipped: DL_SERVE_URL is not set (run verify/dl test --http)")
  end)
else
  local transport
  if REX then
    transport = require("distilled.transport.exec_curl")(REX.exec)
  else
    transport = require("distilled.transport.popen_curl")()
  end
  local s = serve.client(transport)
  t.describe("otlp_http over HTTP (dl serve)", function()
    t.it("the server receives a decodable export", function()
      s.reset()
      s.script("/otlp/v1/traces", { { status = 200, json = { partialSuccess = json.object({}) } } })
      local exp = otlp_http({ endpoint = BASE .. "/otlp", transport = transport })
      t.truthy(exp(sample_spans(), { service_name = "svc-http" }))
      local log = s.requests()
      t.eq(#log, 1)
      t.eq(log[1].path, "/otlp/v1/traces")
      t.eq(log[1].headers["content-type"], "application/json")
      local spans = otlp.decode(json.decode(log[1].body))
      t.eq(#spans, 2)
      t.eq(spans[2].name, "inner")
      t.eq(spans[2].parent_span_id, spans[1].span_id)
    end)
    t.it("an error status and a refused connection are returned, not raised", function()
      s.script("/otlp-bad/v1/traces", { { status = 415, body = "unsupported" } })
      local ok, err =
        otlp_http({ endpoint = BASE .. "/otlp-bad", transport = transport })(sample_spans())
      t.falsy(ok)
      t.match(err.message, "HTTP 415", true)
      ok, err =
        otlp_http({ endpoint = "http://127.0.0.1:1", transport = transport })(sample_spans())
      t.falsy(ok)
      t.eq(err.tag, "SdkError")
      t.eq(err.cause.tag, "TransportError")
    end)
  end)
end
