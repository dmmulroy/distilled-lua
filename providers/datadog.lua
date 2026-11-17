-- Datadog's provider spec.
--
-- Mirrors Distilled's hand-written Datadog glue (packages/datadog/src/):
-- - credentials.ts: the API key from DD_API_KEY; the application key from DD_APP_KEY
--   (optional); the site from DD_SITE, default datadoghq.com, base URL
--   https://api.{site} (apiBaseUrlForSite) unless DD_API_BASE_URL gives it.
-- - protocol.ts: DD-API-KEY, DD-APPLICATION-KEY when set, Accept JSON; failures are
--   { errors = [text | { detail | title, code | status }] } or { code, message }.
-- - errors.ts: UnknownDatadogError, DatadogParseError.
return {
  name = "datadog",
  title = "Datadog",
  base_url = { default = "https://api.{site}", option = "base_url", env = "DD_API_BASE_URL" },
  auth = { kind = "header", header = "DD-API-KEY", from = "api_key", env = "DD_API_KEY" },
  options = {
    application_key = { secret = true, env = "DD_APP_KEY", doc = "DD-APPLICATION-KEY" },
    site = { env = "DD_SITE", default = "datadoghq.com", doc = "Datadog site" },
  },
  headers = { ["DD-APPLICATION-KEY"] = "{application_key}" },
  error_envelope = {
    code = { "/errors/0/code", "/errors/0/status", "/code" },
    message = { "/errors/0", "/errors/0/detail", "/errors/0/title", "/message" },
  },
  unknown_tag = "UnknownDatadogError",
  parse_tag = "DatadogParseError",
}
