-- Zendesk's provider spec.
--
-- Mirrors Distilled's hand-written Zendesk glue (packages/zendesk/src/):
-- - credentials.ts: an OAuth access token from ZENDESK_ACCESS_TOKEN (Bearer), else
--   ZENDESK_EMAIL and ZENDESK_API_TOKEN (Basic "<email>/token:<api token>"); the base
--   URL from ZENDESK_API_BASE_URL (trailing slashes removed), else ZENDESK_SUBDOMAIN:
--   trimmed, scheme and trailing slashes removed, https://<x> when it has a dot, else
--   https://<x>.zendesk.com (originFromSubdomain, glue/zendesk.lua).
-- - protocol.ts: Accept JSON; failures are { error | code, description | message |
--   error }.
-- - errors.ts: UnknownZendeskError, ZendeskParseError.
return {
  name = "zendesk",
  title = "Zendesk",
  base_url = {
    default = "{subdomain}",
    option = "base_url",
    env = "ZENDESK_API_BASE_URL",
    trim_slash = true,
  },
  options = {
    access_token = { secret = true, env = "ZENDESK_ACCESS_TOKEN" },
    email = { env = "ZENDESK_EMAIL" },
    api_token = { secret = true, env = "ZENDESK_API_TOKEN" },
    subdomain = { env = "ZENDESK_SUBDOMAIN", doc = "acme, or acme.zendesk.com" },
  },
  require_one_of = { "access_token", "api_token" },
  headers = {
    Authorization = { "Bearer {access_token}", { basic = "{email}/token:{api_token}" } },
  },
  error_envelope = {
    code = { "/error", "/code" },
    message = { "/description", "/message", "/error" },
  },
  glue = "glue/zendesk.lua",
  unknown_tag = "UnknownZendeskError",
  parse_tag = "ZendeskParseError",
}
