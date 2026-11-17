-- Resend's provider spec.
--
-- Mirrors Distilled's hand-written Resend glue (packages/resend/src/):
-- - credentials.ts: the key from RESEND_API_KEY; the base URL from RESEND_API_BASE_URL,
--   default https://api.resend.com.
-- - protocol.ts: bearer auth; User-Agent distilled.cloud-resend (USER_AGENT); failures
--   are { name | code, message }.
-- - pagination.ts (paginateResend) is task 12's.
-- - errors.ts: UnknownResendError, ResendParseError.
return {
  name = "resend",
  title = "Resend",
  base_url = {
    default = "https://api.resend.com",
    option = "base_url",
    env = "RESEND_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "RESEND_API_KEY" },
  user_agent = "distilled.cloud-resend",
  error_envelope = { code = { "/name", "/code" }, message = "/message" },
  unknown_tag = "UnknownResendError",
  parse_tag = "ResendParseError",
}
