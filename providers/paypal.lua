-- PayPal's provider spec.
--
-- Mirrors Distilled's hand-written PayPal glue (packages/paypal/src/):
-- - credentials.ts: the token from PAYPAL_ACCESS_TOKEN; the base URL from
--   PAYPAL_API_BASE_URL, default https://api-m.paypal.com (sandbox:
--   https://api-m.sandbox.paypal.com).
-- - protocol.ts: bearer auth; failures are { name | code, message }.
-- - errors.ts: UnknownPaypalError, PaypalParseError.
return {
  name = "paypal",
  title = "Paypal",
  base_url = {
    default = "https://api-m.paypal.com",
    option = "base_url",
    env = "PAYPAL_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "PAYPAL_ACCESS_TOKEN" },
  error_envelope = { code = { "/name", "/code" }, message = "/message" },
  unknown_tag = "UnknownPaypalError",
  parse_tag = "PaypalParseError",
}
