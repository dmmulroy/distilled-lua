-- Mercury's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Mercury glue (packages/mercury/src/):
-- - credentials.ts: the key from MERCURY_API_KEY; the base URL from MERCURY_API_BASE_URL,
--   default https://api.mercury.com/api/v1.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownMercuryError, MercuryParseError.
return {
  name = "mercury",
  title = "Mercury",
  base_url = {
    default = "https://api.mercury.com/api/v1",
    option = "base_url",
    env = "MERCURY_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "MERCURY_API_KEY" },
  unknown_tag = "UnknownMercuryError",
  parse_tag = "MercuryParseError",
}
