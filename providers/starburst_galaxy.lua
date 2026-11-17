-- Starburst Galaxy's provider spec.
--
-- Mirrors Distilled's hand-written Starburst Galaxy glue (packages/starburst-galaxy/src/):
-- - credentials.ts: OAuth 2.0 client credentials: STARBURST_GALAXY_CLIENT_ID and
--   STARBURST_GALAXY_CLIENT_SECRET are exchanged (HTTP Basic, form grant_type) at
--   {origin}/oauth/v2/token, the token reused for max(lifetime - 60 s, lifetime / 2);
--   or a given access token (fromAccessToken). The domain from STARBURST_GALAXY_DOMAIN:
--   a host or URL, an origin only, https unless http on a loopback host (apiBaseUrlFor).
-- - protocol.ts: bearer auth; 412 is PreconditionFailed; rateLimited reads the wait
--   of a 429 from "try again in N seconds", else Retry-After (glue/starburst_galaxy.lua).
-- - errors.ts: PreconditionFailed, UnknownStarburstGalaxyError, StarburstGalaxyParseError.
return {
  name = "starburst_galaxy",
  title = "StarburstGalaxy",
  base_url = {
    default = "{domain}",
    option = "base_url",
    origin = {
      label = "Starburst Galaxy domain",
      example = "yourco.galaxy.starburst.io",
      bare_host = true,
    },
  },
  options = {
    access_token = { secret = true, doc = "a Galaxy access token (instead of client credentials)" },
    domain = {
      env = "STARBURST_GALAXY_DOMAIN",
      required = true,
      doc = "yourco.galaxy.starburst.io",
    },
    client_id = { env = "STARBURST_GALAXY_CLIENT_ID" },
    client_secret = { secret = true, env = "STARBURST_GALAXY_CLIENT_SECRET" },
  },
  headers = { Authorization = "Bearer {access_token}" },
  oauth = {
    token_url = "{base_url}/oauth/v2/token",
    client_id = "client_id",
    client_secret = "client_secret",
    into = "access_token",
    auth = "basic",
    reuse = "half",
    refresh_window_s = 60,
    required = true,
    label = "Starburst Galaxy token request",
  },
  error_classes = { PreconditionFailed = { categories = { "ConflictError" } } },
  status_map = { [412] = "PreconditionFailed" },
  glue = "glue/starburst_galaxy.lua",
  unknown_tag = "UnknownStarburstGalaxyError",
  parse_tag = "StarburstGalaxyParseError",
}
