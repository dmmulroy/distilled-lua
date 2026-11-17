-- GrowthBook's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written GrowthBook glue (packages/growthbook/src/):
-- - credentials.ts: the key from GROWTHBOOK_API_KEY; the base URL from GROWTHBOOK_API_BASE_URL,
--   default https://api.growthbook.io/api.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownGrowthBookError, GrowthBookParseError.
return {
  name = "growthbook",
  title = "GrowthBook",
  base_url = {
    default = "https://api.growthbook.io/api",
    option = "base_url",
    env = "GROWTHBOOK_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "GROWTHBOOK_API_KEY" },
  unknown_tag = "UnknownGrowthBookError",
  parse_tag = "GrowthBookParseError",
}
