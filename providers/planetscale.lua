-- PlanetScale's provider spec.
--
-- Mirrors Distilled's hand-written PlanetScale glue (packages/planetscale/src/):
-- - credentials.ts: a service token (PLANETSCALE_API_TOKEN_ID and PLANETSCALE_API_TOKEN)
--   or an OAuth access token (fromOAuth, no environment variable); the organization from
--   PLANETSCALE_ORGANIZATION (required); base URL https://api.planetscale.com/v1 (the
--   environment cannot change it).
-- - protocol.ts: Authorization "Bearer <access token>" or "<token id>:<token>"
--   (formatHeaders).
-- - errors.ts: UnknownPlanetScaleError, PlanetScaleParseError.
return {
  name = "planetscale",
  title = "PlanetScale",
  base_url = { default = "https://api.planetscale.com/v1", option = "base_url" },
  options = {
    access_token = { secret = true, doc = "OAuth access token (instead of a service token)" },
    token_id = { secret = true, env = "PLANETSCALE_API_TOKEN_ID" },
    token = { secret = true, env = "PLANETSCALE_API_TOKEN" },
    organization = { env = "PLANETSCALE_ORGANIZATION", required = true },
  },
  require_one_of = { "access_token", "token" },
  headers = { Authorization = { "Bearer {access_token}", "{token_id}:{token}" } },
  unknown_tag = "UnknownPlanetScaleError",
  parse_tag = "PlanetScaleParseError",
}
