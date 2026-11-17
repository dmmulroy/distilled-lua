-- Questrade's provider spec.
--
-- Mirrors Distilled's hand-written Questrade glue (packages/questrade/src/):
-- - credentials.ts: QUESTRADE_ACCESS_TOKEN with QUESTRADE_API_SERVER when both are set;
--   otherwise QUESTRADE_REFRESH_TOKEN, redeemed at QUESTRADE_LOGIN_URL (default
--   https://login.questrade.com; practice accounts: https://practicelogin.questrade.com)
--   on first use and again shortly before each expiry, following the rotation
--   (glue/questrade.lua). The API server is trimmed of trailing slashes and of /v1.
-- - protocol.ts: Authorization: Bearer <access token> to the token's API server; the
--   operation routes carry /v1. Failures are { code, message } with a numeric code (the
--   default envelope), then the status classes, then UnknownQuestradeError.
-- - errors.ts: UnknownQuestradeError, QuestradeParseError.
return {
  name = "questrade",
  title = "Questrade",
  -- the base URL is the token's API server (glue.base_url); base_url only aims a client
  -- at a mock or a proxy
  base_url = { default = "{api_server}", option = "base_url" },
  options = {
    api_server = {
      env = "QUESTRADE_API_SERVER",
      doc = "the API server access_token was issued for (a redeemed refresh token names its own)",
    },
    access_token = { secret = true, env = "QUESTRADE_ACCESS_TOKEN" },
    refresh_token = {
      secret = true,
      env = "QUESTRADE_REFRESH_TOKEN",
      doc = "redeemed for an access token (it rotates: each one redeems once)",
    },
    login_url = { env = "QUESTRADE_LOGIN_URL", default = "https://login.questrade.com" },
  },
  headers = { Authorization = "Bearer {access_token}" },
  glue = "glue/questrade.lua",
  unknown_tag = "UnknownQuestradeError",
  parse_tag = "QuestradeParseError",
}
