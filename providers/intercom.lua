-- Intercom's provider spec.
--
-- Mirrors Distilled's hand-written Intercom glue (packages/intercom/src/):
-- - credentials.ts: the token from INTERCOM_ACCESS_TOKEN, else INTERCOM_API_KEY; the API
--   version from INTERCOM_API_VERSION, default 2.16; the base URL from
--   INTERCOM_API_BASE_URL, default https://api.intercom.io.
-- - protocol.ts: bearer auth, Accept JSON, Intercom-Version; failures are
--   { errors = [{ code, message }] } or { code, message }.
-- - errors.ts: UnknownIntercomError, IntercomParseError.
return {
  name = "intercom",
  title = "Intercom",
  base_url = {
    default = "https://api.intercom.io",
    option = "base_url",
    env = "INTERCOM_API_BASE_URL",
  },
  auth = {
    kind = "bearer",
    from = "api_key",
    env = { "INTERCOM_ACCESS_TOKEN", "INTERCOM_API_KEY" },
  },
  options = { api_version = { env = "INTERCOM_API_VERSION", default = "2.16" } },
  headers = { ["Intercom-Version"] = "{api_version}" },
  error_envelope = {
    code = { "/errors/0/code", "/code" },
    message = { "/errors/0/message", "/message" },
  },
  unknown_tag = "UnknownIntercomError",
  parse_tag = "IntercomParseError",
}
