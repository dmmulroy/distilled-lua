-- Slack's provider spec (36 models, one per Web API method family: chat,
-- conversations, users, admin, ...).
--
-- Mirrors Distilled's hand-written Slack glue (packages/slack/src/):
-- - credentials.ts: one bearer token from SLACK_BOT_TOKEN, else SLACK_TOKEN; its prefix
--   is its kind (xoxb- bot, xoxp- user, xoxe.* rotating, xapp- app-level) and the header
--   is the same for all, so there is no token-type option. The base URL from
--   SLACK_API_URL, default https://slack.com/api.
-- - protocol.ts: the OAuth exchange methods (models oauth and openid) authenticate with
--   client_id/client_secret arguments instead, so their token is optional and no
--   Authorization header is sent without one (Distilled: an empty token). Query lists
--   comma-joined, form fields JSON-encoded, `ok: false` envelopes mapped by slug
--   (glue/slack.lua).
-- - errors.ts: SlackError (the slug as code, needed, provided, messages),
--   SlackRateLimited (throttling, Retry-After), SlackHttpError (no envelope; status,
--   message, body), SlackParseError.
-- - generate.ts: wire names as in Slack's docs (no member renaming); no per-operation
--   error classes; cursor pagination on response_metadata.next_cursor ("" ends it).
local OPTIONAL_TOKEN = {
  auth = {
    kind = "bearer",
    from = "token",
    env = { "SLACK_BOT_TOKEN", "SLACK_TOKEN" },
    optional = true,
  },
}

return {
  name = "slack",
  title = "Slack",
  base_url = { default = "https://slack.com/api", option = "base_url", env = "SLACK_API_URL" },
  auth = { kind = "bearer", from = "token", env = { "SLACK_BOT_TOKEN", "SLACK_TOKEN" } },
  models = { override = { oauth = OPTIONAL_TOKEN, openid = OPTIONAL_TOKEN } },
  glue = "glue/slack.lua",
  unknown_tag = "SlackHttpError",
  parse_tag = "SlackParseError",
}
