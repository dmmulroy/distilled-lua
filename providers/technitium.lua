-- Technitium DNS Server's provider spec (13 models).
--
-- Mirrors Distilled's hand-written Technitium glue (packages/technitium/src/):
-- - credentials.ts: the token from TECHNITIUM_API_TOKEN; the server from
--   TECHNITIUM_API_URL (required): an origin only, https unless http on a loopback host
--   (normalizeApiUrl).
-- - protocol.ts: bearer auth, Accept JSON; every 2xx answer is an envelope { status,
--   response, errorMessage, innerErrorMessage, ... } (readEnvelope, glue/technitium.lua):
--   "ok" yields `response` (or the body without the envelope members), "error" is
--   TechnitiumError ("Access was denied." is Forbidden), "invalid-token" Unauthorized,
--   "2fa-required" TwoFactorAuthRequired, a body that is not an object or another status
--   UnknownTechnitiumError; a non-2xx answer is read by status with errorMessage.
-- - errors.ts: TechnitiumError, TwoFactorAuthRequired, UnknownTechnitiumError,
--   TechnitiumParseError.
--
-- Not mirrored: withoutCredentials (scrubbing an HttpClientError; the runtime's
-- transport errors never carry the request headers).
return {
  name = "technitium",
  title = "Technitium",
  base_url = {
    option = "base_url",
    env = "TECHNITIUM_API_URL",
    origin = { label = "Technitium API URL", example = "https://dns.example.com:53443" },
  },
  auth = { kind = "bearer", from = "api_token", env = "TECHNITIUM_API_TOKEN" },
  error_envelope = { message = "/errorMessage" },
  glue = "glue/technitium.lua",
  unknown_tag = "UnknownTechnitiumError",
  parse_tag = "TechnitiumParseError",
}
