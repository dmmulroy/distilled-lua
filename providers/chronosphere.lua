-- Chronosphere's provider spec.
--
-- Mirrors Distilled's hand-written Chronosphere glue (packages/chronosphere/src/):
-- - credentials.ts: the token from CHRONOSPHERE_API_TOKEN; the base URL (required) from
--   CHRONOSPHERE_API_BASE_URL, else CHRONOSPHERE_DOMAIN, through originFrom: trailing
--   slashes removed; kept when it has a scheme; https://<x> when it has a dot, else
--   https://<x>.chronosphere.io (glue/chronosphere.lua). The actor from CHRONOSPHERE_ACTOR.
-- - protocol.ts: the token in both API-Token and Authorization: Bearer; Accept JSON;
--   Chronosphere-Actor when an actor is set.
-- - errors.ts: UnknownChronosphereError, ChronosphereParseError.
return {
  name = "chronosphere",
  title = "Chronosphere",
  base_url = {
    option = "base_url",
    env = { "CHRONOSPHERE_API_BASE_URL", "CHRONOSPHERE_DOMAIN" },
  },
  auth = { kind = "bearer", from = "api_key", env = "CHRONOSPHERE_API_TOKEN" },
  options = { actor = { env = "CHRONOSPHERE_ACTOR", doc = "Chronosphere-Actor header" } },
  headers = { ["API-Token"] = "{api_key}", ["Chronosphere-Actor"] = "{actor}" },
  glue = "glue/chronosphere.lua",
  unknown_tag = "UnknownChronosphereError",
  parse_tag = "ChronosphereParseError",
}
