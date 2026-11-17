-- The generated Slack clients (clients/slack/) over the scripted transport: what
-- Distilled's SlackProtocol (packages/slack/src/protocol.ts) and errors.ts do, case by
-- case. No network.
local t = require("spec.harness")
local json = require("distilled.json")
local testing = require("distilled.testing")
local url = require("distilled.url")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local TOKEN = "xoxb-SPEC-FAKE-TOKEN"

local function client(module, opts, responses)
  local host = testing.host({ responses = responses or {}, env = opts.env or {} })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  return require(module).new(o), host
end

local function form(body)
  local out = {}
  for pair in string.gmatch(body, "[^&]+") do
    local k, v = string.match(pair, "^([^=]*)=(.*)$")
    out[url.decode_form and url.decode_form(k) or k] = v
  end
  return out
end

local function unescape(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

t.describe("slack: requests (SlackProtocol encode, serializeForWire)", function()
  t.it("bearer token from SLACK_BOT_TOKEN, else SLACK_TOKEN; https://slack.com/api", function()
    local c, host = client("slack.chat", { env = { SLACK_TOKEN = TOKEN } }, {
      { status = 200, body = { ok = true, channel = "C1", ts = "1.2" } },
    })
    local res, err =
      c:post_message({ channel = "C1", text = "hi", blocks = { { type = "divider" } } })
    t.eq(err, nil)
    t.eq(res.ok, true)
    local req = host.requests[1]
    t.eq(req.url, "https://slack.com/api/chat.postMessage")
    t.eq(req.headers.authorization, "Bearer " .. TOKEN)
    -- a JSON operation keeps its lists as JSON
    t.eq(req.headers["content-type"], "application/json")
    t.same(json.decode(req.body).blocks, { { type = "divider" } })
  end)

  t.it("no token is a ConfigError naming both variables", function()
    local c, host = client("slack.chat", {})
    local _, err = c:post_message({ channel = "C1", text = "hi" })
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "SLACK_BOT_TOKEN", true)
    t.match(err.message, "SLACK_TOKEN", true)
    t.eq(#host.requests, 0)
  end)

  t.it("the OAuth exchange methods need no token and send no Authorization", function()
    local c, host = client("slack.oauth", {}, { { status = 200, body = { ok = true } } })
    local _, err = c:v2_access({ client_id = "1.2", client_secret = "cs-FAKE", code = "abc" })
    t.eq(err, nil)
    local req = host.requests[1]
    t.eq(req.headers.authorization, nil)
    t.eq(req.headers["content-type"], "application/x-www-form-urlencoded")
    local f = form(req.body)
    t.eq(f.client_secret, "cs-FAKE")
    t.eq(f.code, "abc")
  end)

  t.it("a query list is one comma-joined parameter", function()
    local c, host = client("slack.admin", { token = TOKEN }, {
      { status = 200, body = { ok = true, bulk_action_id = "b1" } },
    })
    local _, err =
      c:bulk_set_exclude_from_slack_ai({ channel_ids = { "C1", "C2" }, exclude = true })
    t.eq(err, nil)
    local q = string.match(host.requests[1].url, "%?(.*)$")
    t.eq(q, "channel_ids=C1%2CC2&exclude=true")
  end)

  t.it("form fields: lists of scalars comma-joined, the rest JSON", function()
    local c, host = client("slack.admin", { token = TOKEN }, {
      { status = 200, body = { ok = true, barrier = {} } },
    })
    local _, err = c:create_barrier({
      primary_usergroup_id = "S1",
      barriered_from_usergroup_ids = { "S2", "S3" },
      restricted_subjects = { "im", "mpim" },
    })
    t.eq(err, nil)
    local f = form(host.requests[1].body)
    t.eq(unescape(f.barriered_from_usergroup_ids), "S2,S3")
    t.eq(unescape(f.restricted_subjects), "im,mpim")
    t.eq(f["barriered_from_usergroup_ids[0]"], nil, "no bracket notation")
  end)

  t.it("SLACK_API_URL moves the base URL", function()
    local c, host = client("slack.conversations", {
      env = { SLACK_BOT_TOKEN = TOKEN, SLACK_API_URL = "http://127.0.0.1:9/api" },
    }, { { status = 200, body = { ok = true, channels = {} } } })
    c:list_conversations({ limit = 2 })
    t.eq(host.requests[1].url, "http://127.0.0.1:9/api/conversations.list?limit=2")
  end)
end)

t.describe("slack: answers (SlackProtocol decode, errors.ts)", function()
  local function call(responses)
    local c, host = client("slack.chat", { token = TOKEN }, responses)
    local res, err = c:post_message({ channel = "C1", text = "hi" })
    return res, err, host
  end

  t.it("ok:false with HTTP 200 is a SlackError carrying the slug", function()
    local _, err = call({
      {
        status = 200,
        body = {
          ok = false,
          error = "missing_scope",
          needed = "chat:write",
          provided = "users:read",
        },
      },
    })
    t.eq(err.tag, "SlackError")
    t.eq(err.code, "missing_scope")
    t.eq(err.message, "missing_scope")
    t.eq(err.needed, "chat:write")
    t.eq(err.provided, "users:read")
    t.eq(err.retryable, false)
  end)

  t.it("response_metadata.messages is the message and the messages field", function()
    local _, err = call({
      {
        status = 200,
        body = {
          ok = false,
          error = "invalid_arguments",
          response_metadata = { messages = { "[ERROR] missing required field: channel" } },
        },
      },
    })
    t.eq(err.tag, "SlackError")
    t.eq(err.code, "invalid_arguments")
    t.eq(err.message, "[ERROR] missing required field: channel")
    t.same(err.messages, { "[ERROR] missing required field: channel" })
  end)

  t.it("credential slugs are Unauthorized", function()
    local _, err = call({ { status = 200, body = { ok = false, error = "invalid_auth" } } })
    t.eq(err.tag, "Unauthorized")
    t.eq(err.message, "invalid_auth")
    t.no_match(err.message, TOKEN, true)
  end)

  t.it("server slugs are retryable server errors", function()
    local _, err = call({ { status = 200, body = { ok = false, error = "service_unavailable" } } })
    t.eq(err.tag, "ServiceUnavailable")
    t.eq(err.retryable, true)
    _, err = call({ { status = 200, body = { ok = false, error = "request_timeout" } } })
    t.eq(err.tag, "GatewayTimeout")
    _, err = call({ { status = 200, body = { ok = false, error = "fatal_error" } } })
    t.eq(err.tag, "InternalServerError")
  end)

  t.it("a 429 is SlackRateLimited with the Retry-After hint; ratelimited too", function()
    local _, err = call({
      {
        status = 429,
        headers = { ["Retry-After"] = "30" },
        body = { ok = false, error = "ratelimited" },
      },
    })
    t.eq(err.tag, "SlackRateLimited")
    t.eq(err.code, "ratelimited")
    t.eq(err.retry_after, 30)
    t.eq(err.throttling, true)
    t.eq(err.retryable, true)
    _, err = call({ { status = 200, body = { ok = false, error = "rate_limited" } } })
    t.eq(err.tag, "SlackRateLimited")
  end)

  t.it("is retried by the default policy, then succeeds", function()
    local host = testing.host({
      responses = {
        {
          status = 429,
          headers = { ["retry-after"] = "1" },
          body = { ok = false, error = "ratelimited" },
        },
        { status = 200, body = { ok = true, channel = "C1", ts = "1" } },
      },
    })
    local c = require("slack.chat").new({ host = host, token = TOKEN })
    local res, err = c:post_message({ channel = "C1", text = "hi" })
    t.eq(err, nil)
    t.eq(res.ok, true)
    t.eq(#host.requests, 2)
    t.truthy(host.sleeps[1] >= 1)
  end)

  t.it("no envelope: the status classes, then SlackHttpError with the text", function()
    local _, err = call({ { status = 502, body = "<html>bad gateway</html>" } })
    t.eq(err.tag, "BadGateway")
    t.eq(err.message, "<html>bad gateway</html>")
    _, err = call({ { status = 418, body = string.rep("x", 3000) } })
    t.eq(err.tag, "SlackHttpError")
    t.eq(err.status, 418)
    t.eq(#err.body, 2000)
    _, err = call({ { status = 418, body = "" } })
    t.eq(err.message, "HTTP 418")
  end)

  t.it("an empty-cursor page ends the traversal", function()
    local c, host = client("slack.conversations", { token = TOKEN }, {
      {
        status = 200,
        body = {
          ok = true,
          channels = { { id = "C1" } },
          response_metadata = { next_cursor = "dXNlcjpV" },
        },
      },
      {
        status = 200,
        body = { ok = true, channels = { { id = "C2" } }, response_metadata = { next_cursor = "" } },
      },
    })
    local items, err = c:list_conversations_items({ limit = 1 }):collect()
    t.eq(err, nil)
    t.eq(#items, 2)
    t.eq(items[2].id, "C2")
    t.match(host.requests[2].url, "cursor=dXNlcjpV", true)
  end)
end)
