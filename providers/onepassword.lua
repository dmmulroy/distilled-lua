-- 1Password's provider spec (models connect, events, oauth, users, partnership).
--
-- Mirrors Distilled's hand-written 1Password glue (packages/onepassword/src/):
-- - credentials.ts (Connect server, model connect): the token from OP_CONNECT_TOKEN;
--   the base URL from OP_CONNECT_API_BASE_URL, else OP_CONNECT_HOST with /v1 appended
--   unless it ends with /v1 in any case (connectHostToBaseUrl, glue/onepassword.lua),
--   default http://localhost:8080/v1.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownOnepasswordError, OnepasswordParseError.
--
-- The other models need task 10's per-model override, once it covers auth and options:
-- events (bearer OP_EVENTS_API_TOKEN, OP_EVENTS_API_BASE_URL default
-- https://events.1password.com, message Error.Message); oauth (Basic
-- OP_USERS_API_CLIENT_ID:OP_USERS_API_CLIENT_SECRET, OP_USERS_API_BASE_URL default
-- https://api.1password.com, code error, message error_description | error); users
-- (the oauth block: client credentials at {base}/v1/oauth/token, default TTL 900 s);
-- partnership (bearer OP_PARTNERSHIP_API_TOKEN, OP_PARTNERSHIP_API_BASE_URL default
-- https://billing.1password.com, code error, message description | error).
return {
  name = "onepassword",
  title = "Onepassword",
  base_url = {
    default = "http://localhost:8080/v1",
    option = "base_url",
    env = "OP_CONNECT_API_BASE_URL",
    trim_slash = true,
  },
  auth = { kind = "bearer", from = "token", env = "OP_CONNECT_TOKEN" },
  options = { connect_host = { env = "OP_CONNECT_HOST", doc = "the Connect server (gets /v1)" } },
  glue = "glue/onepassword.lua",
  unknown_tag = "UnknownOnepasswordError",
  parse_tag = "OnepasswordParseError",
}
