-- Sentry's provider spec.
--
-- Mirrors Distilled's hand-written Sentry glue (packages/sentry/src/):
-- - credentials.ts: the token from SENTRY_AUTH_TOKEN, else SENTRY_API_KEY; the base URL
--   from SENTRY_URL, else SENTRY_API_BASE_URL, default https://sentry.io.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownSentryError, SentryParseError.
return {
  name = "sentry",
  title = "Sentry",
  base_url = {
    default = "https://sentry.io",
    option = "base_url",
    env = { "SENTRY_URL", "SENTRY_API_BASE_URL" },
  },
  auth = { kind = "bearer", from = "api_key", env = { "SENTRY_AUTH_TOKEN", "SENTRY_API_KEY" } },
  unknown_tag = "UnknownSentryError",
  parse_tag = "SentryParseError",
}
