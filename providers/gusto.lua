-- Gusto's provider spec.
--
-- Mirrors Distilled's hand-written Gusto glue (packages/gusto/src/):
-- - credentials.ts: the token from GUSTO_ACCESS_TOKEN, else GUSTO_API_TOKEN, else
--   GUSTO_API_KEY; the API version from GUSTO_API_VERSION, default 2026-06-15; the base
--   URL from GUSTO_API_BASE_URL, default https://api.gusto.com.
-- - protocol.ts: bearer auth and an X-Gusto-API-Version header; failures are
--   { errors = [{ category, error_key, message }] } or { code, message }.
-- - errors.ts: UnknownGustoError, GustoParseError.
return {
  name = "gusto",
  title = "Gusto",
  base_url = {
    default = "https://api.gusto.com",
    option = "base_url",
    env = "GUSTO_API_BASE_URL",
  },
  auth = {
    kind = "bearer",
    from = "api_key",
    env = { "GUSTO_ACCESS_TOKEN", "GUSTO_API_TOKEN", "GUSTO_API_KEY" },
  },
  options = {
    api_version = { env = "GUSTO_API_VERSION", default = "2026-06-15", doc = "Gusto API version" },
  },
  headers = { ["X-Gusto-API-Version"] = "{api_version}" },
  error_envelope = {
    code = { "/errors/0/category", "/errors/0/error_key", "/code" },
    message = { "/errors/0/message", "/message" },
  },
  unknown_tag = "UnknownGustoError",
  parse_tag = "GustoParseError",
  naming = { members = "wire" },
}
