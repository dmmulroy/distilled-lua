-- Okta's provider spec.
--
-- Mirrors Distilled's hand-written Okta glue (packages/okta/src/):
-- - credentials.ts: the token from OKTA_API_TOKEN; the org URL from OKTA_ORG_URL
--   (required, trailing slashes removed); the scheme from OKTA_AUTH_SCHEME, SSWS
--   (default) or Bearer (anything else is SSWS; fromAccessToken is Bearer).
-- - protocol.ts: Authorization "<scheme> <token>", Accept JSON; failures are
--   { errorCode | code, errorSummary | message }.
-- - errors.ts: UnknownOktaError, OktaParseError.
return {
  name = "okta",
  title = "Okta",
  base_url = { option = "base_url", env = "OKTA_ORG_URL", trim_slash = true },
  options = {
    api_token = { secret = true, env = "OKTA_API_TOKEN", required = true },
    auth_scheme = {
      env = "OKTA_AUTH_SCHEME",
      default = "SSWS",
      choices = { "SSWS", "Bearer" },
      invalid = "default",
    },
  },
  headers = { Authorization = "{auth_scheme} {api_token}" },
  error_envelope = { code = { "/errorCode", "/code" }, message = { "/errorSummary", "/message" } },
  unknown_tag = "UnknownOktaError",
  parse_tag = "OktaParseError",
}
