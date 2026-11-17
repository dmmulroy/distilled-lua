-- Adyen's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Adyen glue (packages/adyen/src/):
-- - credentials.ts: the key from ADYEN_API_KEY; the base URL from ADYEN_API_BASE_URL,
--   default https://checkout-test.adyen.com/v72.
-- - protocol.ts: an X-API-Key header; failures are { errorCode, message }.
-- - errors.ts: UnknownAdyenError, AdyenParseError.
return {
  name = "adyen",
  title = "Adyen",
  base_url = {
    default = "https://checkout-test.adyen.com/v72",
    option = "base_url",
    env = "ADYEN_API_BASE_URL",
  },
  auth = { kind = "header", header = "X-API-Key", from = "api_key", env = "ADYEN_API_KEY" },
  error_envelope = { code = "/errorCode", message = "/message" },
  unknown_tag = "UnknownAdyenError",
  parse_tag = "AdyenParseError",
}
