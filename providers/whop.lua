-- Whop's provider spec.
--
-- Mirrors Distilled's hand-written Whop glue (packages/whop/src/):
-- - credentials.ts: the key from WHOP_API_KEY; the base URL from WHOP_API_BASE_URL,
--   default https://api.whop.com/api/v1 (sandbox: https://sandbox-api.whop.com/api/v1);
--   the API version date from WHOP_API_VERSION_DATE, default 2026-09-25
--   (api-version.ts API_VERSION_DATE).
-- - protocol.ts: bearer auth, Api-Version-Date; failures are { error = text } or
--   { error = { code | type, message } }; 402 is PaymentRequired.
-- - errors.ts: PaymentRequired, UnknownWhopError, WhopParseError.
return {
  name = "whop",
  title = "Whop",
  base_url = {
    default = "https://api.whop.com/api/v1",
    option = "base_url",
    env = "WHOP_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "WHOP_API_KEY" },
  options = { api_version_date = { env = "WHOP_API_VERSION_DATE", default = "2026-09-25" } },
  headers = { ["Api-Version-Date"] = "{api_version_date}" },
  error_envelope = {
    code = { "/error/code", "/error/type" },
    message = { "/error", "/error/message" },
  },
  error_classes = { PaymentRequired = { categories = { "BadRequestError" } } },
  status_map = { [402] = "PaymentRequired" },
  unknown_tag = "UnknownWhopError",
  parse_tag = "WhopParseError",
}
