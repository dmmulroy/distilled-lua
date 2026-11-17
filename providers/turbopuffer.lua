-- Turbopuffer's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Turbopuffer glue (packages/turbopuffer/src/):
-- - credentials.ts: the key from TURBOPUFFER_API_KEY; the base URL from TURBOPUFFER_API_BASE_URL,
--   default https://gcp-us-central1.turbopuffer.com.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownTurbopufferError, TurbopufferParseError.
return {
  name = "turbopuffer",
  title = "Turbopuffer",
  base_url = {
    default = "https://gcp-us-central1.turbopuffer.com",
    option = "base_url",
    env = "TURBOPUFFER_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "TURBOPUFFER_API_KEY" },
  unknown_tag = "UnknownTurbopufferError",
  parse_tag = "TurbopufferParseError",
}
