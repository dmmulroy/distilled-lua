-- Customer.io's provider spec.
--
-- Mirrors Distilled's hand-written Customer.io glue (packages/customerio/src/):
-- - credentials.ts: the key from CUSTOMERIO_API_KEY; the base URL from
--   CUSTOMERIO_API_BASE_URL, default https://api.customer.io.
-- - protocol.ts: bearer auth; failures are JSON:API errors, { meta = { errors } } or
--   { message | error } (the first text value of each list wins).
-- - errors.ts: UnknownCustomerioError, CustomerioParseError.
return {
  name = "customerio",
  title = "Customerio",
  base_url = {
    default = "https://api.customer.io",
    option = "base_url",
    env = "CUSTOMERIO_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "CUSTOMERIO_API_KEY" },
  error_envelope = {
    code = { "/errors/0/status", "/errors/0/code", "/code" },
    message = { "/errors/0/detail", "/errors/0/message", "/meta/errors/0", "/message", "/error" },
  },
  unknown_tag = "UnknownCustomerioError",
  parse_tag = "CustomerioParseError",
}
