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
-- The other models have their own credentials and protocol (models.override):
-- - events (EventsCredentials, EventsProtocol): bearer OP_EVENTS_API_TOKEN, base URL
--   OP_EVENTS_API_BASE_URL default https://events.1password.com; failures
--   { Error = { Message } }.
-- - oauth (OAuthCredentials, OAuthProtocol): Basic OP_USERS_API_CLIENT_ID:
--   OP_USERS_API_CLIENT_SECRET, base URL OP_USERS_API_BASE_URL default
--   https://api.1password.com; failures { error, error_description }.
-- - users (UsersCredentials, UsersProtocol): a bearer access token, or one exchanged
--   from the oauth client credentials (client_credentials grant, Basic auth, POST
--   {base}/v1/oauth/token; expires_in default 900 s, refreshed 60 s early); the same
--   base URL.
-- - partnership (PartnershipCredentials, PartnershipProtocol): bearer
--   OP_PARTNERSHIP_API_TOKEN, base URL OP_PARTNERSHIP_API_BASE_URL default
--   https://billing.1password.com; failures { error, description }.
-- Every base URL is trimmed of trailing slashes (trimBase).
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
  models = {
    override = {
      events = {
        base_url = { default = "https://events.1password.com", env = "OP_EVENTS_API_BASE_URL" },
        auth = { kind = "bearer", from = "token", env = "OP_EVENTS_API_TOKEN" },
        options = false,
        glue = false,
        error_envelope = { message = "/Error/Message" },
      },
      oauth = {
        base_url = { default = "https://api.1password.com", env = "OP_USERS_API_BASE_URL" },
        auth = { kind = "basic", username = "client_id", password = "client_secret" },
        options = {
          client_id = { env = "OP_USERS_API_CLIENT_ID", required = true },
          client_secret = { secret = true, env = "OP_USERS_API_CLIENT_SECRET", required = true },
        },
        glue = false,
        error_envelope = { code = "/error", message = { "/error_description", "/error" } },
      },
      users = {
        base_url = { default = "https://api.1password.com", env = "OP_USERS_API_BASE_URL" },
        auth = false,
        options = {
          access_token = { secret = true, doc = "an access token you hold (no exchange)" },
          client_id = { env = "OP_USERS_API_CLIENT_ID" },
          client_secret = { secret = true, env = "OP_USERS_API_CLIENT_SECRET" },
        },
        headers = { Authorization = "Bearer {access_token}" },
        oauth = {
          token_url = "{base_url}/v1/oauth/token",
          client_id = "client_id",
          client_secret = "client_secret",
          into = "access_token",
          auth = "basic",
          default_ttl_s = 900,
          refresh_window_s = 60,
          required = true,
          label = "1Password Users API token exchange",
        },
        glue = false,
      },
      partnership = {
        base_url = {
          default = "https://billing.1password.com",
          env = "OP_PARTNERSHIP_API_BASE_URL",
        },
        auth = { kind = "bearer", from = "token", env = "OP_PARTNERSHIP_API_TOKEN" },
        options = false,
        glue = false,
        error_envelope = { code = "/error", message = { "/description", "/error" } },
      },
    },
  },
  unknown_tag = "UnknownOnepasswordError",
  parse_tag = "OnepasswordParseError",
}
