-- Coolify's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Coolify glue (packages/coolify/src/):
-- - credentials.ts: the key from COOLIFY_TOKEN; the base URL from COOLIFY_API_BASE_URL,
--   default https://app.coolify.io/api/v1.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownCoolifyError, CoolifyParseError.
return {
  name = "coolify",
  title = "Coolify",
  base_url = {
    default = "https://app.coolify.io/api/v1",
    option = "base_url",
    env = "COOLIFY_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "COOLIFY_TOKEN" },
  unknown_tag = "UnknownCoolifyError",
  parse_tag = "CoolifyParseError",
}
