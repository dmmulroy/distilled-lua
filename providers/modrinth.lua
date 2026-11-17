-- Modrinth's provider spec.
--
-- Mirrors Distilled's hand-written Modrinth glue (packages/modrinth/src/):
-- - credentials.ts: an optional key from MODRINTH_API_KEY; the base URL from
--   MODRINTH_API_BASE_URL, default https://api.modrinth.com/v2; the User-Agent from
--   MODRINTH_USER_AGENT, default distilled.cloud-modrinth (Modrinth requires one).
-- - protocol.ts: the raw key in Authorization when set; failures are
--   { error, description | message }.
-- - errors.ts: UnknownModrinthError, ModrinthParseError.
return {
  name = "modrinth",
  title = "Modrinth",
  base_url = {
    default = "https://api.modrinth.com/v2",
    option = "base_url",
    env = "MODRINTH_API_BASE_URL",
  },
  auth = {
    kind = "header",
    header = "Authorization",
    from = "api_key",
    env = "MODRINTH_API_KEY",
    optional = true,
  },
  user_agent = { default = "distilled.cloud-modrinth", env = "MODRINTH_USER_AGENT" },
  error_envelope = { code = { "/error", "/code" }, message = { "/description", "/message" } },
  unknown_tag = "UnknownModrinthError",
  parse_tag = "ModrinthParseError",
}
