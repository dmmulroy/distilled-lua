-- Squarespace's provider spec.
--
-- Mirrors Distilled's hand-written Squarespace glue (packages/squarespace/src/):
-- - credentials.ts: the key from SQUARESPACE_API_KEY; the base URL from
--   SQUARESPACE_API_BASE_URL, default https://api.squarespace.com; the User-Agent from
--   SQUARESPACE_USER_AGENT, default distilled.cloud-squarespace (Squarespace requires one).
-- - protocol.ts: bearer auth; failures are { subtype | type | code, message }.
-- - errors.ts: UnknownSquarespaceError, SquarespaceParseError.
return {
  name = "squarespace",
  title = "Squarespace",
  base_url = {
    default = "https://api.squarespace.com",
    option = "base_url",
    env = "SQUARESPACE_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "SQUARESPACE_API_KEY" },
  user_agent = { default = "distilled.cloud-squarespace", env = "SQUARESPACE_USER_AGENT" },
  error_envelope = { code = { "/subtype", "/type", "/code" }, message = "/message" },
  unknown_tag = "UnknownSquarespaceError",
  parse_tag = "SquarespaceParseError",
}
