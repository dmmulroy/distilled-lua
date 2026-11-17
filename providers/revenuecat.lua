-- RevenueCat's provider spec.
--
-- Mirrors Distilled's hand-written RevenueCat glue (packages/revenuecat/src/):
-- - credentials.ts: the key from REVENUECAT_API_KEY; the base URL from
--   REVENUECAT_API_BASE_URL, default https://api.revenuecat.com/v2.
-- - protocol.ts: bearer auth; failures are { type, message }.
-- - pagination.ts (paginateNextPage) is task 12's.
-- - errors.ts: UnknownRevenueCatError, RevenueCatParseError.
return {
  name = "revenuecat",
  title = "RevenueCat",
  base_url = {
    default = "https://api.revenuecat.com/v2",
    option = "base_url",
    env = "REVENUECAT_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "REVENUECAT_API_KEY" },
  error_envelope = { code = "/type", message = "/message" },
  unknown_tag = "UnknownRevenueCatError",
  parse_tag = "RevenueCatParseError",
}
