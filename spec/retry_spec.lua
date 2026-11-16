-- Retry: server hint parsing, policies, budget, deadline and the run loop. Ports
-- retry.test.ts and retry-after.test.ts (numbers and names kept); the end-to-end cases
-- run a real client over the scripted transport with random pinned, as Distilled pins
-- Math.random, and read the waits from the fake host's sleeps.
local t = require("spec.harness")
local retry = require("distilled.retry")
local errors = require("distilled.errors")
local trace = require("distilled.trace")
local expect = require("distilled.trace.expect")
local Client = require("distilled.client")
local rest = require("distilled.protocol.rest")
local S = require("distilled.schema")
local testing = require("distilled.testing")

-- Date.parse("2026-10-05T12:00:00Z") / 1000
local NOW = 1791201600

local function ms_list(sleeps)
  local out = {}
  for i, s in ipairs(sleeps) do
    out[i] = math.floor(s * 1000 + 0.5)
  end
  return out
end

local function thing_service()
  local input = S.struct({ name = "ThingRequest", members = {} })
  local output =
    S.struct({ name = "Out", members = { S.member({ name = "ok", schema = S.boolean }) } })
  local function op(name, method, extra)
    local o =
      { name = name, method = method, uri = "/thing", input = input, output = output, errors = {} }
    for k, v in pairs(extra or {}) do
      o[k] = v
    end
    return o
  end
  return {
    name = "test",
    shapes = {},
    errors = {},
    telemetry = { system = "test-api", prefix = "Test", service = "Test" },
    ops = {
      get_thing = op("GetThing", "GET", { span = "GetThing" }),
      create_thing = op("CreateThing", "POST"),
      -- an operation whose model sets distilled.retry#policy
      get_tuned = op("GetTuned", "GET", { retry = { max_attempts = 4, base_ms = 100 } }),
    },
  }
end

local Test = Client.define({
  service = thing_service(),
  protocol = rest.new({ base_url = "https://api.test", unknown_tag = "UnknownTestError" }),
})

local function status(code, headers)
  return { status = code, headers = headers, body = { message = "status " .. code } }
end
local function ok()
  return { status = 200, body = { ok = true } }
end
local function transport_error()
  return errors.new("TransportError", { message = "reset" })
end

-- n failures made by reply(), then a success
local function fail_times(n, reply)
  local list = {}
  for i = 1, n do
    list[i] = reply()
  end
  list[n + 1] = ok()
  return list
end
local function always(reply, n)
  local list = {}
  for i = 1, n or 40 do
    list[i] = reply()
  end
  return list
end

-- run(responses, { random, client = { ...options }, op, tracer }) -> value, err, host
local function run(responses, opts)
  opts = opts or {}
  local host = testing.host({ responses = responses, epoch = NOW, env = opts.env })
  local r = opts.random or 0.5
  host.random = function()
    return r
  end
  local options = { host = host }
  for k, v in pairs(opts.client or {}) do
    options[k] = v
  end
  local client = Test.new(options)
  local value, err = client[opts.op or "get_thing"](client, {})
  return value, err, host, client
end

local function field_methods(requests)
  local out = {}
  for i, r in ipairs(requests) do
    out[i] = r.method
  end
  return out
end

local TRANSIENT = {
  errors.new("TooManyRequests"),
  errors.new("Locked"),
  errors.new("InternalServerError"),
  errors.new("BadGateway"),
  errors.new("ServiceUnavailable"),
  errors.new("GatewayTimeout"),
  errors.new(errors.define({ tag = "RetryableMarked", retryable = true })),
  errors.new(errors.define({ tag = "CategorizedNetworkError", categories = { "NetworkError" } })),
  errors.new("TransportError"),
}
-- a category describes an error; only a mark retries it
local PERMANENT = {
  errors.new(errors.define({ tag = "CategorizedTimeoutError", categories = { "TimeoutError" } })),
  errors.new("BadRequest"),
  errors.new("Unauthorized"),
  errors.new("Forbidden"),
  errors.new("NotFound"),
  errors.new("Conflict"),
  errors.new("UnknownTestError"),
  errors.new("ParseError"),
  "plain",
  false,
}

t.describe("retry predicates by error category", function()
  t.it("default and transient policies retry every transient error", function()
    for _, e in ipairs(TRANSIENT) do
      t.eq(retry.DEFAULT.when(e), true, e.tag)
      t.eq(retry.TRANSIENT.when(e), true, e.tag)
    end
  end)

  t.it("no policy retries a permanent error", function()
    for _, e in ipairs(PERMANENT) do
      for _, p in ipairs({ retry.DEFAULT, retry.TRANSIENT, retry.THROTTLING, retry.NONE }) do
        t.eq(p.when(e), false, tostring(e))
      end
    end
  end)

  t.it("throttling policies retry only throttling errors", function()
    t.eq(retry.THROTTLING.when(errors.new("TooManyRequests")), true)
    for i = 2, #TRANSIENT do
      t.eq(retry.THROTTLING.when(TRANSIENT[i]), false, TRANSIENT[i].tag)
    end
  end)
end)

t.describe("retry: the default policy (makeDefault schedule)", function()
  t.it("full jitter from 50ms, and gives up after 2 retries", function()
    retry.default_budget:reset()
    local v, err, host = run(always(function()
      return status(503)
    end))
    t.eq(v, nil)
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(#host.requests, 3)
    -- random 0.5 x 50ms x 2^n
    t.same(ms_list(host.sleeps), { 25, 50 })
  end)

  t.it("each delay is a random fraction of the exponential delay", function()
    retry.default_budget:reset()
    local _, _, host = run(
      fail_times(2, function()
        return status(503)
      end),
      { random = 0 }
    )
    t.same(ms_list(host.sleeps), { 0, 0 })
  end)

  t.it("succeeds as soon as a retry succeeds", function()
    retry.default_budget:reset()
    local v, _, host = run(fail_times(2, function()
      return status(503)
    end))
    t.eq(v.ok, true)
    t.eq(#host.requests, 3)
  end)

  t.it("throttling errors back off from 1s", function()
    retry.default_budget:reset()
    local _, _, host = run(fail_times(2, function()
      return status(429)
    end))
    t.same(ms_list(host.sleeps), { 500, 1000 })
  end)

  t.it("retries wire-level transport failures", function()
    retry.default_budget:reset()
    local v, _, host = run(fail_times(2, transport_error))
    t.eq(v.ok, true)
    t.same(ms_list(host.sleeps), { 25, 50 })
  end)

  t.it("retries the statuses core's error classes mark: 500, 502, 503, 504, 408, 423", function()
    for _, code in ipairs({ 500, 502, 503, 504, 408, 423 }) do
      retry.default_budget:reset()
      local v, _, host = run(always(function()
        return status(code)
      end))
      t.eq(v, nil)
      t.eq(#host.requests, 3, tostring(code))
    end
  end)

  t.it("does not retry non-transient failures", function()
    for _, code in ipairs({ 400, 401, 403, 404, 409, 422, 402 }) do
      local v, _, host = run(always(function()
        return status(code)
      end))
      t.eq(v, nil)
      t.eq(#host.requests, 1, tostring(code))
    end
  end)

  t.it("does not distinguish mutations from reads", function()
    retry.default_budget:reset()
    local _, _, reads = run(fail_times(2, function()
      return status(503)
    end))
    local _, _, writes = run(
      fail_times(2, function()
        return status(503)
      end),
      { op = "create_thing" }
    )
    t.same(field_methods(writes.requests), { "POST", "POST", "POST" })
    t.same(writes.sleeps, reads.sleeps)
  end)
end)

t.describe("retry: distilled.retry#policy override (op.retry)", function()
  t.it("replaces the default policy's numbers", function()
    retry.default_budget:reset()
    local _, _, host = run(
      always(function()
        return status(503)
      end),
      { op = "get_tuned" }
    )
    t.eq(#host.requests, 4)
    -- random 0.5 x 100ms x 2^n
    t.same(ms_list(host.sleeps), { 50, 100, 200 })
  end)

  t.it("keeps the default's other numbers", function()
    retry.default_budget:reset()
    local _, _, host = run(
      fail_times(1, function()
        return status(429)
      end),
      { op = "get_tuned" }
    )
    t.same(ms_list(host.sleeps), { 500 })
  end)

  t.it("a caller's policy ignores it", function()
    local _, _, host = run(
      always(function()
        return status(503)
      end),
      { op = "get_tuned", client = { retry = "none" } }
    )
    t.eq(#host.requests, 1)
    local _, _, host2 = run(
      always(function()
        return status(503)
      end),
      { op = "get_tuned", client = { retry = { max_retries = 1, budget = false } } }
    )
    t.eq(#host2.requests, 2)
  end)

  t.it("retry = { deadline_s } alone is no policy: the operation's numbers still apply", function()
    retry.default_budget:reset()
    local _, _, host = run(
      always(function()
        return status(503)
      end),
      { op = "get_tuned", client = { retry = { deadline_s = 100 } } }
    )
    t.eq(#host.requests, 4)
  end)
end)

t.describe("retry: budget", function()
  t.it(
    "a bucket starts with 100 tokens: 7 transient retries, then the call fails at once",
    function()
      retry.default_budget:reset()
      local total = 0
      for _ = 1, 4 do
        local _, _, host = run(always(function()
          return status(503)
        end))
        total = total + #host.requests
      end
      -- 3 calls x 2 retries = 6 retries (84 tokens), then 1 retry (14 tokens), then none
      t.eq(total, 4 + 7)
      t.eq(retry.default_budget:tokens("api.test"), 2)
      local _, _, more = run(always(function()
        return status(503)
      end))
      t.eq(#more.requests, 1)
    end
  )

  t.it("a throttling retry costs 5 tokens", function()
    retry.default_budget:reset()
    run(always(function()
      return status(429)
    end))
    t.eq(retry.default_budget:tokens("api.test"), 90)
  end)

  t.it("a successful response adds a token, up to 500", function()
    retry.default_budget:reset()
    run(always(function()
      return status(503)
    end))
    t.eq(retry.default_budget:tokens("api.test"), 72)
    for _ = 1, 3 do
      run({ ok() })
    end
    t.eq(retry.default_budget:tokens("api.test"), 75)
    local b = retry.new_budget({ initial = 499 })
    b:success("h")
    b:success("h")
    t.eq(b:tokens("h"), 500)
  end)

  t.it("a retry that succeeds gets its cost back", function()
    retry.default_budget:reset()
    run(fail_times(1, function()
      return status(503)
    end))
    t.eq(retry.default_budget:tokens("api.test"), 100)
  end)

  t.it("buckets are per host", function()
    local budget = retry.new_budget({ initial = 14 })
    t.eq(budget:withdraw("a.test", false), 14)
    t.eq(budget:withdraw("a.test", false), nil)
    t.eq(budget:withdraw("b.test", false), 14)
  end)

  t.it("a try that sent nothing (no host recorded) is not budgeted", function()
    local budget = retry.new_budget({ initial = 0 })
    local calls = { n = 0 }
    local _, err = retry.run(function()
      calls.n = calls.n + 1
      return nil, errors.new("ServiceUnavailable")
    end, {
      policy = {
        when = function()
          return true
        end,
        base_ms = 0,
        factor = 1,
        cap_ms = 0,
        max_retries = 2,
        budget = budget,
      },
      host = testing.host({}),
    })
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(calls.n, 3)
  end)

  t.it("an empty bucket stops at once, and the trace says why", function()
    local memory = trace.exporters.memory()
    local host = testing.host({})
    local tracer = trace.new({ level = "operation", exporter = memory, host = host })
    local _, err, h = run(
      always(function()
        return status(503)
      end),
      { client = { budget = retry.new_budget({ initial = 0 }), tracer = tracer } }
    )
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(#h.requests, 1)
    expect(memory.spans)
      :span("Test.GetThing")
      :attr("distilled.retry.stopped", "budget")
      :no_attr("distilled.attempts")
  end)

  t.it("a long-poll operation still backs off when the budget is empty", function()
    local function ended_at(long_poll)
      local _, _, host = run(
        always(function()
          return status(503)
        end),
        {
          client = {
            retry = {
              when = function()
                return true
              end,
              full_jitter = false,
              base_ms = 400,
              factor = 2,
              cap_ms = 1000,
              long_poll = long_poll,
            },
            budget = retry.new_budget({ initial = 0 }),
          },
        }
      )
      t.eq(#host.requests, 1)
      return host.now()
    end
    t.eq(ended_at(false), 0)
    -- no full jitter and no jitter_ms: the delay is the 400ms base
    t.eq(math.floor(ended_at(true) * 1000 + 0.5), 400)
  end)

  t.it("a policy without a budget is not limited", function()
    local v, _, host = run(
      fail_times(10, function()
        return status(503)
      end),
      { client = { retry = retry.TRANSIENT }, random = 0 }
    )
    t.eq(v.ok, true)
    t.eq(#host.requests, 11)
  end)

  t.it("a budget is shared by a client and every client derived from it with `with`", function()
    local budget = retry.new_budget({ initial = 28 })
    local host = testing.host({
      responses = always(function()
        return status(503)
      end),
    })
    host.random = function()
      return 0
    end
    local client = Test.new({ host = host, budget = budget })
    local derived = client:with({ validation = "strict" })
    client:get_thing({})
    derived:get_thing({})
    -- 28 tokens: 2 retries in total
    t.eq(#host.requests, 3 + 1)
    t.eq(budget:tokens("api.test"), 0)
  end)

  t.it("clients that pass no budget share the module default", function()
    retry.default_budget:reset()
    run(always(function()
      return status(503)
    end))
    run(always(function()
      return status(503)
    end))
    t.eq(retry.default_budget:tokens("api.test"), 100 - 4 * 14)
  end)
end)

t.describe("retry: server hints", function()
  t.it("Retry-After is the least the default policy waits", function()
    retry.default_budget:reset()
    local _, _, host = run(fail_times(2, function()
      return status(503, { ["retry-after"] = "2" })
    end))
    t.same(ms_list(host.sleeps), { 2000, 2000 })
  end)

  t.it("a Retry-After shorter than the backoff does not shorten it", function()
    retry.default_budget:reset()
    local _, _, host = run(fail_times(1, function()
      return status(429, { ["retry-after"] = "0" })
    end))
    t.same(ms_list(host.sleeps), { 500 })
  end)

  t.it("a Retry-After longer than the 20s backoff cap is honored in full", function()
    retry.default_budget:reset()
    local _, _, host = run(fail_times(1, function()
      return status(429, { ["retry-after"] = "30" })
    end))
    t.same(ms_list(host.sleeps), { 30000 })
  end)

  t.it("a Retry-After over the hint cap fails instead of retrying early", function()
    t.eq(retry.DEFAULT_SERVER_HINT_CAP_S, 60)
    retry.default_budget:reset()
    local _, err, host = run(fail_times(1, function()
      return status(429, { ["retry-after"] = "600" })
    end))
    t.eq(err.tag, "TooManyRequests")
    t.eq(#host.requests, 1)
  end)

  local function attempts_under(client_opts, env)
    retry.default_budget:reset()
    local _, _, host = run(
      fail_times(1, function()
        return status(429, { ["retry-after"] = "2" })
      end),
      { client = client_opts, env = env }
    )
    return #host.requests
  end

  t.it("server_hint_cap_s sets the cap", function()
    t.eq(attempts_under({ server_hint_cap_s = 1.5 }), 1)
    t.eq(attempts_under({ server_hint_cap_s = 2.5 }), 2)
    t.eq(attempts_under({ retry = { server_hint_cap_s = 1.5 } }), 1)
  end)

  t.it("DISTILLED_SERVER_RETRY_HINT_CAP_MS (through host.getenv) sets the cap", function()
    t.eq(attempts_under(nil, { DISTILLED_SERVER_RETRY_HINT_CAP_MS = "1500" }), 1)
    t.eq(attempts_under(nil, { DISTILLED_SERVER_RETRY_HINT_CAP_MS = "2500" }), 2)
  end)

  t.it("an invalid DISTILLED_SERVER_RETRY_HINT_CAP_MS falls back to the default cap", function()
    for _, raw in ipairs({ "-1", "soon", "Infinity", "" }) do
      t.eq(attempts_under(nil, { DISTILLED_SERVER_RETRY_HINT_CAP_MS = raw }), 2, raw)
    end
  end)

  t.it("DISTILLED_SERVER_RETRY_HINT_CAP_MS is truncated to whole milliseconds", function()
    t.eq(attempts_under(nil, { DISTILLED_SERVER_RETRY_HINT_CAP_MS = "1999.9" }), 1)
  end)

  t.it("the option wins over the environment", function()
    t.eq(
      attempts_under({ server_hint_cap_s = 1 }, { DISTILLED_SERVER_RETRY_HINT_CAP_MS = "2500" }),
      1
    )
  end)

  t.it("the throttling preset honors hints", function()
    local _, _, host = run(
      fail_times(1, function()
        return status(429, { ["retry-after"] = "3" })
      end),
      { client = { retry = "throttling" } }
    )
    t.same(ms_list(host.sleeps), { 3000 })
  end)

  t.it("a hint over the cap is recorded on the operation span", function()
    local memory = trace.exporters.memory()
    local tracer = trace.new({ level = "operation", exporter = memory, host = testing.host({}) })
    retry.default_budget:reset()
    run(
      fail_times(1, function()
        return status(429, { ["retry-after"] = "600" })
      end),
      { client = { tracer = tracer } }
    )
    expect(memory.spans):span("Test.GetThing"):attr("distilled.retry.stopped", "hint_over_cap")
  end)
end)

t.describe("retry: bounded server hints (x-amz-retry-after, x-distilled-retry-after)", function()
  local function delay_for(code, headers)
    retry.default_budget:reset()
    local _, _, host = run(fail_times(1, function()
      return status(code, headers)
    end))
    return ms_list(host.sleeps)
  end

  for _, header in ipairs({ "x-amz-retry-after", "x-distilled-retry-after" }) do
    t.it(header .. " within [t, t + 5s] is used as is", function()
      t.same(delay_for(503, { [header] = "3000" }), { 3000 })
    end)
    t.it(header .. " below the backoff waits the backoff", function()
      t.same(delay_for(503, { [header] = "10" }), { 25 })
    end)
    t.it(header .. " is clamped to the backoff plus 5s", function()
      t.same(delay_for(503, { [header] = "60000" }), { 5025 })
    end)
    t.it(header .. " that is not whole milliseconds is ignored", function()
      for _, value in ipairs({ "abc", "-5", "1.5", "" }) do
        t.same(delay_for(503, { [header] = value }), { 25 }, value)
      end
    end)
    t.it(header .. " does not make an error retryable", function()
      t.same(delay_for(400, { [header] = "3000" }), {})
      t.same(delay_for(404, { [header] = "3000" }), {})
    end)
  end

  t.it("the larger of the two headers wins", function()
    t.same(
      delay_for(503, { ["x-amz-retry-after"] = "1000", ["x-distilled-retry-after"] = "2000" }),
      { 2000 }
    )
  end)

  t.it("Retry-After is ignored when a bounded hint is present", function()
    t.same(delay_for(429, { ["retry-after"] = "30", ["x-distilled-retry-after"] = "700" }), { 700 })
    t.same(delay_for(429, { ["retry-after"] = "600", ["x-amz-retry-after"] = "700" }), { 700 })
  end)

  t.it("a hint applies only to the retry after the response that carried it", function()
    retry.default_budget:reset()
    local _, _, host =
      run({ status(503, { ["x-distilled-retry-after"] = "3000" }), transport_error(), ok() })
    t.same(ms_list(host.sleeps), { 3000, 50 })
  end)
end)

t.describe("retry: throttling and transient presets", function()
  t.it(
    "transient policies back off from 1s, cap at 5s, and keep retrying past 8 attempts",
    function()
      local v, _, host = run(
        fail_times(10, function()
          return status(503)
        end),
        { client = { retry = "transient" }, random = 0 }
      )
      t.eq(v.ok, true)
      t.same(ms_list(host.sleeps), { 1000, 2000, 4000, 5000, 5000, 5000, 5000, 5000, 5000, 5000 })
    end
  )

  t.it("throttling policies do not retry server errors", function()
    local _, err, host = run(
      always(function()
        return status(503)
      end),
      { client = { retry = retry.THROTTLING } }
    )
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(#host.requests, 1)
  end)

  t.it("min_throttle_ms floors throttling delays without full jitter", function()
    local _, _, host = run(
      fail_times(1, function()
        return status(429)
      end),
      {
        client = {
          retry = {
            full_jitter = false,
            base_ms = 10,
            factor = 2,
            cap_ms = 100,
            min_throttle_ms = 300,
            budget = false,
          },
        },
        random = 0,
      }
    )
    t.same(ms_list(host.sleeps), { 300 })
  end)
end)

t.describe("retry: policy resolution", function()
  t.it("a policy that never retries disables the default", function()
    local _, _, host = run(
      always(function()
        return status(503)
      end),
      { client = { retry = retry.NONE } }
    )
    t.eq(#host.requests, 1)
  end)

  t.it("a policy without a backoff retries immediately while its predicate holds", function()
    local calls = { n = 0 }
    local v = retry.run(function()
      calls.n = calls.n + 1
      if calls.n < 4 then
        return nil, errors.new("BadRequest")
      end
      return "done"
    end, {
      policy = {
        when = function()
          return true
        end,
      },
      host = testing.host({}),
    })
    t.eq(v, "done")
    t.eq(calls.n, 4)
  end)

  t.it("a `when` that raises becomes an SdkError", function()
    local _, err = run(
      always(function()
        return status(503)
      end),
      {
        client = {
          retry = {
            when = function()
              error("boom")
            end,
          },
        },
      }
    )
    t.eq(err.tag, "SdkError")
    t.match(err.message, "boom", true)
  end)

  t.it("policy_for: presets, names, fields and the op override", function()
    local p = retry.policy_for(nil, nil)
    t.eq(p.max_retries, 2)
    t.eq(p.base_ms, 50)
    t.eq(p.budget, retry.default_budget)
    p = retry.policy_for(nil, { max_attempts = 4, base_ms = 100, long_poll = true })
    t.eq(p.max_retries, 3)
    t.eq(p.base_ms, 100)
    t.eq(p.long_poll, true)
    t.eq(p.throttling_base_ms, 1000)
    p = retry.policy_for("transient", { max_attempts = 9 })
    t.eq(p.max_retries, nil)
    t.eq(p.cap_ms, 5000)
    local settings
    p, settings = retry.policy_for({ max_retries = 5, deadline_s = 20 }, { max_attempts = 9 })
    t.eq(p.max_retries, 5)
    t.eq(p.base_ms, 50)
    t.eq(settings.deadline_s, 20)
    p = retry.policy_for({ preset = "throttling", cap_ms = 1 })
    t.eq(p.when, errors.is_throttling)
    t.eq(p.cap_ms, 1)
    -- the presets are not changed by resolution
    t.eq(retry.DEFAULT.max_retries, 2)
  end)

  t.it("check_spec refuses unknown names and wrong types", function()
    t.raises(function()
      retry.check_spec({ max_retry = 1 })
    end, "unknown retry option max_retry")
    t.raises(function()
      retry.check_spec({ base_ms = "50" })
    end, "base_ms must be a number")
    t.raises(function()
      retry.check_spec("sometimes")
    end, "unknown retry preset")
    t.raises(function()
      retry.check_spec({ budget = {} })
    end, "budget")
    t.raises(function()
      Test.new({ retry = { max_retry = 1 } })
    end, "valid: ")
  end)

  t.it("the first call runs with no retry bookkeeping on the span", function()
    local memory = trace.exporters.memory()
    local tracer = trace.new({ level = "debug", exporter = memory, host = testing.host({}) })
    run({ ok() }, { client = { tracer = tracer } })
    local e = expect(memory.spans)
    e:span("Test.GetThing"):ok():no_attr("distilled.attempts"):no_attr("distilled.retry.delay_ms")
    e:spans("distilled.attempt"):count(1)
    e:spans("distilled.retry.backoff"):count(0)
  end)
end)

t.describe("retry: deadline", function()
  local POLICY = {
    when = errors.is_transient,
    full_jitter = false,
    base_ms = 400,
    factor = 2,
    cap_ms = 10000,
    max_retries = 10,
    budget = false,
  }

  t.it("stops before a sleep that would pass the deadline and returns the last error", function()
    local memory = trace.exporters.memory()
    local host_for_trace = testing.host({})
    local tracer = trace.new({ level = "debug", exporter = memory, host = host_for_trace })
    local _, err, host = run(
      { status(503), status(502), status(500) },
      { client = { retry = POLICY, deadline_s = 1, tracer = tracer } }
    )
    -- 400ms (t = 0.4), then 800ms would end at 1.2 > 1
    t.eq(err.tag, "BadGateway")
    t.eq(#host.requests, 2)
    t.same(ms_list(host.sleeps), { 400 })
    local e = expect(memory.spans)
    e:span("Test.GetThing")
      :failed("BadGateway")
      :attr("distilled.retry.stopped", "deadline")
      :attr("distilled.attempts", 2)
      :attr("distilled.retry.delay_ms", 400)
    e:spans("distilled.attempt"):count(2)
    e:span("distilled.retry.backoff")
      :attr("distilled.retry.delay_ms", 400)
      :attr("distilled.retry.reason", "ServiceUnavailable")
  end)

  t.it("passes the remaining time to the transport as request.timeout", function()
    local _, _, host = run(
      { status(503), status(503), ok() },
      { client = { retry = POLICY, deadline_s = 10 } }
    )
    t.eq(#host.requests, 3)
    t.eq(host.requests[1].timeout, 10)
    t.eq(math.floor(host.requests[2].timeout * 1000 + 0.5), 9600)
    t.eq(math.floor(host.requests[3].timeout * 1000 + 0.5), 8800)
  end)

  t.it("retry = { deadline_s } is the same as deadline_s", function()
    local _, _, host = run(
      always(function()
        return status(503)
      end),
      {
        client = {
          retry = {
            when = errors.is_transient,
            full_jitter = false,
            base_ms = 400,
            factor = 2,
            cap_ms = 10000,
            max_retries = 10,
            budget = false,
            deadline_s = 1,
          },
        },
      }
    )
    t.eq(#host.requests, 2)
  end)

  t.it("no deadline: no timeout on the request", function()
    retry.default_budget:reset()
    local _, _, host = run({ ok() })
    t.eq(host.requests[1].timeout, nil)
  end)
end)

t.describe("retry: Retry-After parsing (retry-after.test.ts)", function()
  local function ra(v)
    return retry.parse_retry_after({ ["retry-after"] = v }, NOW)
  end

  t.it("delay-seconds: non-negative integers, zero, whitespace, leading zeros", function()
    t.eq(ra("120"), 120)
    t.eq(ra("1"), 1)
    t.eq(ra("0"), 0)
    t.eq(ra("  5\t"), 5)
    t.eq(ra("007"), 7)
  end)

  t.it("signed or fractional numbers are rejected", function()
    for _, raw in ipairs({ "-5", "+5", "1.5", "-0", "0.0" }) do
      t.eq(ra(raw), nil, raw)
    end
  end)

  t.it("HTTP-date: IMF-fixdate relative to now", function()
    t.eq(ra("Mon, 05 Oct 2026 12:00:30 GMT"), 30)
  end)

  t.it("HTTP-date: the obsolete RFC 850 and asctime forms", function()
    t.eq(ra("Monday, 05-Oct-26 12:01:00 GMT"), 60)
    t.eq(ra("Mon Oct  5 12:00:10 2026 GMT"), 10)
    t.eq(ra("Mon Oct  5 12:00:10 2026"), 10)
  end)

  t.it("a date in the past, or equal to now, is zero", function()
    t.eq(ra("Mon, 05 Oct 2026 11:00:00 GMT"), 0)
    t.eq(ra("Mon, 05 Oct 2026 12:00:00 GMT"), 0)
  end)

  t.it("absent or invalid headers", function()
    t.eq(retry.parse_retry_after(nil), nil)
    t.eq(retry.parse_retry_after({}), nil)
    t.eq(ra(""), nil)
    t.eq(ra("   "), nil)
    for _, raw in ipairs({ "soon", "5s", "PT5S", "tomorrow at noon" }) do
      t.eq(ra(raw), nil, raw)
    end
    -- only the lowercase key is read
    t.eq(retry.parse_retry_after({ ["Retry-After"] = "5" }), nil)
  end)

  t.it("parse_http_date across a leap day and the epoch", function()
    t.eq(retry.parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT"), 0)
    t.eq(retry.parse_http_date("Thu, 29 Feb 2024 00:00:00 GMT"), 1709164800)
    t.eq(retry.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"), 784111777)
    t.eq(retry.parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT"), 784111777)
    t.eq(retry.parse_http_date("Sun Nov  6 08:49:37 1994"), 784111777)
    t.eq(retry.parse_http_date("Sun, 06 Foo 1994 08:49:37 GMT"), nil)
  end)
end)

t.describe("retry: RateLimit parsing", function()
  local function rl(v)
    return retry.parse_ratelimit({ ratelimit = v })
  end

  t.it("returns the reset time when the remaining quota is zero", function()
    t.eq(rl("r=0, t=30"), 30)
    t.eq(rl("limit=100, remaining=0, reset=30"), 30)
    t.eq(rl('"default";r=0;t=30'), 30)
  end)

  t.it("tolerates whitespace and key case", function()
    t.eq(rl(" R = 0 ;  T = 12 "), 12)
  end)

  t.it("is absent while quota remains", function()
    t.eq(rl("r=5, t=30"), nil)
    t.eq(rl("limit=100, remaining=1, reset=30"), nil)
    t.eq(rl('"default";r=2;t=30'), nil)
  end)

  t.it("is absent unless remaining is present and exactly zero", function()
    for _, v in ipairs({
      "t=30",
      "limit=100, reset=30",
      '"default";t=30',
      "r=-1, t=30",
      "remaining=-1, reset=30",
      "r=0.5, t=30",
      "r=none, t=30",
    }) do
      t.eq(rl(v), nil, v)
    end
  end)

  t.it("is absent without a usable reset", function()
    t.eq(rl("r=0"), nil)
    t.eq(rl("r=0, t=-1"), nil)
    t.eq(rl("r=0, t=later"), nil)
  end)

  t.it("is absent when the header is missing or empty", function()
    t.eq(retry.parse_ratelimit(nil), nil)
    t.eq(retry.parse_ratelimit({}), nil)
    t.eq(rl(""), nil)
  end)
end)

t.describe("retry: parse_server_hint and parse_for_status", function()
  t.it("prefers Retry-After over RateLimit", function()
    t.eq(retry.parse_server_hint({ ["retry-after"] = "5", ratelimit = "r=0, t=30" }), 5)
  end)

  t.it("falls back to RateLimit when Retry-After is absent or invalid", function()
    t.eq(retry.parse_server_hint({ ratelimit = "r=0, t=30" }), 30)
    t.eq(retry.parse_server_hint({ ["retry-after"] = "soon", ratelimit = "r=0, t=30" }), 30)
  end)

  t.it("is absent when neither header yields a value", function()
    t.eq(retry.parse_server_hint({ ratelimit = "r=3, t=30" }), nil)
    t.eq(retry.parse_server_hint({ ratelimit = "t=30" }), nil)
    t.eq(retry.parse_server_hint(nil), nil)
  end)

  t.it("returns the hint for every retryable status and ignores the others", function()
    for status_code in pairs(errors.RETRYABLE_STATUSES) do
      t.eq(retry.parse_for_status(status_code, { ["retry-after"] = "4" }), 4)
    end
    for _, s in ipairs({ 200, 400, 401, 403, 404, 409, 422, 501, 521 }) do
      t.eq(retry.parse_for_status(s, { ["retry-after"] = "4" }), nil, tostring(s))
    end
  end)

  t.it("bounded_hint_ms and host_of", function()
    t.eq(retry.bounded_hint_ms({ ["x-amz-retry-after"] = " 700 " }), 700)
    t.eq(retry.bounded_hint_ms({ ["x-amz-retry-after"] = "1.5" }), nil)
    t.eq(retry.bounded_hint_ms(nil), nil)
    t.eq(retry.host_of("https://user:pw@api.test:8443/a?b#c"), "api.test")
    t.eq(retry.host_of("http://[::1]:80/x"), "[::1]")
    t.eq(retry.host_of("https://[::1]/x"), "[::1]")
    t.eq(retry.host_of("/relative"), "")
  end)
end)

t.describe("retry: Retry-After feeding the default retry delay", function()
  local function delays(code, headers, random)
    retry.default_budget:reset()
    local _, _, host = run({ status(code, headers), ok() }, { random = random or 0 })
    return ms_list(host.sleeps)
  end

  t.it("delay-seconds is the least the default policy waits", function()
    t.same(delays(503, { ["retry-after"] = "3" }), { 3000 })
  end)

  t.it("an HTTP-date waits until that date (host.epoch is now)", function()
    t.same(delays(429, { ["retry-after"] = "Mon, 05 Oct 2026 12:00:04 GMT" }), { 4000 })
  end)

  t.it("a RateLimit reset is used when Retry-After is absent", function()
    t.same(delays(429, { ratelimit = "r=0, t=2" }), { 2000 })
  end)

  t.it("an invalid header falls back to the default backoff", function()
    t.same(delays(503, { ["retry-after"] = "soon" }, 0.5), { 25 })
    t.same(delays(429, { ["retry-after"] = "soon" }, 0.5), { 500 })
  end)

  t.it("a RateLimit header with quota left falls back to the default backoff", function()
    t.same(delays(503, { ratelimit = "r=4, t=30" }, 0.5), { 25 })
  end)

  t.it("a hint on a non-retryable status neither stamps nor triggers a retry", function()
    retry.default_budget:reset()
    local _, err, host = run({ status(404, { ["retry-after"] = "3" }), ok() })
    t.same(host.sleeps, {})
    t.eq(err.retry_after, nil)
  end)
end)
