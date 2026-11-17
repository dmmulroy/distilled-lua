-- Xata's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Xata glue (packages/xata/src/):
-- - credentials.ts: the key from XATA_API_KEY; the base URL from XATA_API_BASE_URL,
--   default https://api.xata.tech.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownXataError, XataParseError.
return {
  name = "xata",
  title = "Xata",
  base_url = {
    default = "https://api.xata.tech",
    option = "base_url",
    env = "XATA_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "XATA_API_KEY" },
  unknown_tag = "UnknownXataError",
  parse_tag = "XataParseError",
}
