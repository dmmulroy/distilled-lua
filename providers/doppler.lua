-- Doppler's provider spec.
--
-- Mirrors Distilled's hand-written Doppler glue (packages/doppler/src/):
-- - credentials.ts: the token from DOPPLER_TOKEN, else DOPPLER_API_KEY; the base URL from
--   DOPPLER_API_BASE_URL, default https://api.doppler.com.
-- - protocol.ts: bearer auth, Accept JSON; failures are { code | error, message |
--   messages[0] }. DopplerPublicProtocol serves AuthOidc and the CLI-auth operations
--   without credentials (scripts/generate.ts PUBLIC_OPERATIONS).
-- - errors.ts: UnknownDopplerError, DopplerParseError.
--
-- Differs from Distilled: the public operations use the base_url option too (Distilled
-- pins them to https://api.doppler.com); `messages` takes its first member only when it
-- is text (Distilled takes the first text member).
return {
  name = "doppler",
  title = "Doppler",
  base_url = {
    default = "https://api.doppler.com",
    option = "base_url",
    env = "DOPPLER_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = { "DOPPLER_TOKEN", "DOPPLER_API_KEY" } },
  public_operations = { "AuthOidc", "GenerateCliAuth", "AuthorizeCliAuth", "RevokeCliAuth" },
  error_envelope = { code = { "/code", "/error" }, message = { "/message", "/messages/0" } },
  unknown_tag = "UnknownDopplerError",
  parse_tag = "DopplerParseError",
}
