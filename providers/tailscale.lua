-- Tailscale's provider spec.
--
-- Mirrors Distilled's hand-written Tailscale glue (packages/tailscale/src/):
-- - credentials.ts: the key from TAILSCALE_API_KEY, or OAuth 2.0 client credentials
--   (TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET) exchanged at
--   {base}/oauth/token with form fields (client_id, client_secret, scope, tailnet), the
--   token refreshed 60 s before expires_in; both at once is a ConfigError
--   (BOTH_METHODS). The origin from TAILSCALE_BASE_URL gets /api/v2 unless present;
--   default https://api.tailscale.com/api/v2.
-- - protocol.ts: bearer auth; raw-string outputs are decoded from the text and a raw
--   array answered with "null" is [] (the runtime's raw-response handling).
-- - errors.ts: UnknownTailscaleError, TailscaleParseError.
return {
  name = "tailscale",
  title = "Tailscale",
  base_url = {
    default = "https://api.tailscale.com/api/v2",
    option = "base_url",
    env = "TAILSCALE_BASE_URL",
    ensure_suffix = "/api/v2",
  },
  options = {
    api_key = { secret = true, env = "TAILSCALE_API_KEY" },
    client_id = { env = "TAILSCALE_OAUTH_CLIENT_ID" },
    client_secret = { secret = true, env = "TAILSCALE_OAUTH_CLIENT_SECRET" },
    scope = { doc = "OAuth scopes, space separated" },
    token_tailnet = { doc = "the tailnet an OAuth token is for" },
  },
  headers = { Authorization = "Bearer {api_key}" },
  oauth = {
    token_url = "{base_url}/oauth/token",
    client_id = "client_id",
    client_secret = "client_secret",
    into = "api_key",
    auth = "form",
    scope = "scope",
    extra = { tailnet = "token_tailnet" },
    refresh_window_s = 60,
    required = true,
    exclusive = true,
    label = "OAuth token exchange",
  },
  unknown_tag = "UnknownTailscaleError",
  parse_tag = "TailscaleParseError",
}
