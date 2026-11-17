-- Vanta's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Vanta glue (packages/vanta/src/):
-- - credentials.ts: the key from VANTA_ACCESS_TOKEN; the base URL from VANTA_API_BASE_URL,
--   default https://api.vanta.com.
-- - protocol.ts: bearer auth; the default { code, message } envelope; Vanta for Government is base_url = "https://api.vanta-gov.com" (GOV_API_BASE_URL).
-- - errors.ts: UnknownVantaError, VantaParseError.
return {
  name = "vanta",
  title = "Vanta",
  base_url = {
    default = "https://api.vanta.com",
    option = "base_url",
    env = "VANTA_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "VANTA_ACCESS_TOKEN" },
  unknown_tag = "UnknownVantaError",
  parse_tag = "VantaParseError",
}
