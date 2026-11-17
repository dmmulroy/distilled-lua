-- PostHog's provider spec.
--
-- Mirrors Distilled's hand-written PostHog glue (packages/posthog/src/):
-- - credentials.ts: the key from POSTHOG_API_KEY; the base URL from POSTHOG_HOST, default
--   https://us.posthog.com.
-- - protocol.ts: bearer auth; failures are { code | type, detail | message | error }.
-- - errors.ts: UnknownPosthogError, PosthogParseError.
return {
  name = "posthog",
  title = "Posthog",
  base_url = { default = "https://us.posthog.com", option = "base_url", env = "POSTHOG_HOST" },
  auth = { kind = "bearer", from = "api_key", env = "POSTHOG_API_KEY" },
  error_envelope = { code = { "/code", "/type" }, message = { "/detail", "/message", "/error" } },
  unknown_tag = "UnknownPosthogError",
  parse_tag = "PosthogParseError",
}
