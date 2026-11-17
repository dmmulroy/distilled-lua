-- Inngest's provider spec.
--
-- Mirrors Distilled's hand-written Inngest glue (packages/inngest/src/):
-- - credentials.ts: the key from INNGEST_API_KEY; the base URL from INNGEST_API_BASE_URL,
--   default https://api.inngest.com/v2.
-- - protocol.ts: bearer auth; x-inngest-env from the Environment service (here the
--   `environment` option); routes under /v1/ use the base URL's origin
--   (glue/inngest.lua); failures are a text body, { errors = [{ code, message }] } or
--   { code, message | error }.
-- - errors.ts: UnknownInngestError, InngestParseError.
return {
  name = "inngest",
  title = "Inngest",
  base_url = {
    default = "https://api.inngest.com/v2",
    option = "base_url",
    env = "INNGEST_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "INNGEST_API_KEY" },
  options = { environment = { doc = "the Inngest environment (x-inngest-env)" } },
  headers = { ["x-inngest-env"] = "{environment}" },
  error_envelope = {
    code = { "/errors/0/code", "/code" },
    message = { "/errors/0/message", "/message", "/error" },
  },
  glue = "glue/inngest.lua",
  unknown_tag = "UnknownInngestError",
  parse_tag = "InngestParseError",
}
