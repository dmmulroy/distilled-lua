-- LaunchDarkly's provider spec.
--
-- Mirrors Distilled's hand-written LaunchDarkly glue (packages/launchdarkly/src/):
-- - credentials.ts: the token from LAUNCHDARKLY_ACCESS_TOKEN, else LAUNCHDARKLY_API_KEY;
--   the base URL from LAUNCHDARKLY_API_BASE_URL, default https://app.launchdarkly.com;
--   the API version from LAUNCHDARKLY_API_VERSION, default 20240415.
-- - protocol.ts: the raw token in Authorization; LD-API-Version.
-- - errors.ts: UnknownLaunchDarklyError, LaunchDarklyParseError.
return {
  name = "launchdarkly",
  title = "LaunchDarkly",
  base_url = {
    default = "https://app.launchdarkly.com",
    option = "base_url",
    env = "LAUNCHDARKLY_API_BASE_URL",
  },
  auth = {
    kind = "header",
    header = "Authorization",
    from = "api_key",
    env = { "LAUNCHDARKLY_ACCESS_TOKEN", "LAUNCHDARKLY_API_KEY" },
  },
  options = { api_version = { env = "LAUNCHDARKLY_API_VERSION", default = "20240415" } },
  headers = { ["LD-API-Version"] = "{api_version}" },
  unknown_tag = "UnknownLaunchDarklyError",
  parse_tag = "LaunchDarklyParseError",
}
