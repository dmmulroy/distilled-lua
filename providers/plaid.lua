-- Plaid's provider spec.
--
-- Mirrors Distilled's hand-written Plaid glue (packages/plaid/src/):
-- - credentials.ts: the client id from PLAID_CLIENT_ID and secret from PLAID_SECRET; the
--   version from PLAID_VERSION, default 2020-09-14; the base URL from PLAID_API_BASE_URL,
--   else the PLAID_ENV environment (ENV_BASE_URLS; an unknown one is the default),
--   default https://sandbox.plaid.com.
-- - protocol.ts: PLAID-CLIENT-ID, PLAID-SECRET and Plaid-Version headers; failures are
--   { error_code | code, error_message | message }.
-- - errors.ts: UnknownPlaidError, PlaidParseError.
return {
  name = "plaid",
  title = "Plaid",
  base_url = { default = "{environment}", option = "base_url", env = "PLAID_API_BASE_URL" },
  options = {
    client_id = { secret = true, env = "PLAID_CLIENT_ID", required = true },
    secret = { secret = true, env = "PLAID_SECRET", required = true },
    plaid_version = { env = "PLAID_VERSION", default = "2020-09-14" },
    environment = {
      env = "PLAID_ENV",
      default = "sandbox",
      choices = {
        sandbox = "https://sandbox.plaid.com",
        development = "https://development.plaid.com",
        production = "https://production.plaid.com",
      },
      invalid = "default",
    },
  },
  headers = {
    ["PLAID-CLIENT-ID"] = "{client_id}",
    ["PLAID-SECRET"] = "{secret}",
    ["Plaid-Version"] = "{plaid_version}",
  },
  error_envelope = { code = { "/error_code", "/code" }, message = { "/error_message", "/message" } },
  unknown_tag = "UnknownPlaidError",
  parse_tag = "PlaidParseError",
}
