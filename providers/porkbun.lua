-- Porkbun's provider spec.
--
-- Mirrors Distilled's hand-written Porkbun glue (packages/porkbun/src/):
-- - credentials.ts: the key from PORKBUN_API_KEY and secret key from
--   PORKBUN_SECRET_API_KEY; the base URL from PORKBUN_API_BASE_URL, default
--   https://api.porkbun.com/api/json/v3.
-- - protocol.ts: X-API-Key and X-Secret-API-Key headers; failures are { code, message }.
-- - errors.ts: UnknownPorkbunError, PorkbunParseError.
return {
  name = "porkbun",
  title = "Porkbun",
  base_url = {
    default = "https://api.porkbun.com/api/json/v3",
    option = "base_url",
    env = "PORKBUN_API_BASE_URL",
  },
  auth = { kind = "header", header = "X-API-Key", from = "api_key", env = "PORKBUN_API_KEY" },
  options = {
    secret_api_key = { secret = true, env = "PORKBUN_SECRET_API_KEY", required = true },
  },
  headers = { ["X-Secret-API-Key"] = "{secret_api_key}" },
  error_envelope = { code = "/code", message = "/message" },
  unknown_tag = "UnknownPorkbunError",
  parse_tag = "PorkbunParseError",
}
