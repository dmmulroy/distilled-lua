-- Infisical's provider spec.
--
-- Mirrors Distilled's hand-written Infisical glue (packages/infisical/src/):
-- - credentials.ts: an optional token from INFISICAL_TOKEN (anonymous calls allowed);
--   the base URL from INFISICAL_API_BASE_URL, default https://us.infisical.com.
-- - protocol.ts: bearer auth only when a token is set.
-- - errors.ts: UnknownInfisicalError, InfisicalParseError.
return {
  name = "infisical",
  title = "Infisical",
  base_url = {
    default = "https://us.infisical.com",
    option = "base_url",
    env = "INFISICAL_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "INFISICAL_TOKEN", optional = true },
  unknown_tag = "UnknownInfisicalError",
  parse_tag = "InfisicalParseError",
}
