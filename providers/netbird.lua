-- NetBird's provider spec.
--
-- Mirrors Distilled's hand-written NetBird glue (packages/netbird/src/):
-- - credentials.ts: the token from NETBIRD_API_TOKEN; the base URL from NETBIRD_API_URL,
--   default https://api.netbird.io, through normalizeApiBaseUrl: an origin only (no
--   userinfo, path, query or fragment), https unless http on a loopback host; otherwise
--   a ConfigError "NetBird API base URL ...".
-- - protocol.ts: Authorization "Token <token>".
-- - errors.ts: UnknownNetBirdError, NetBirdParseError.
return {
  name = "netbird",
  title = "NetBird",
  base_url = {
    default = "https://api.netbird.io",
    option = "base_url",
    env = "NETBIRD_API_URL",
    origin = { label = "NetBird API base URL", example = "https://api.netbird.io" },
  },
  auth = {
    kind = "header",
    header = "Authorization",
    prefix = "Token ",
    from = "api_token",
    env = "NETBIRD_API_TOKEN",
  },
  unknown_tag = "UnknownNetBirdError",
  parse_tag = "NetBirdParseError",
}
