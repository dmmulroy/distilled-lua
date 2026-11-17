-- Mailchimp's provider spec (models marketing and transactional).
--
-- Mirrors Distilled's hand-written Mailchimp glue (packages/mailchimp/src/):
-- - credentials.ts (Marketing API): the key from MAILCHIMP_API_KEY; the data centre from
--   MAILCHIMP_SERVER_PREFIX, else the key's "-<dc>" suffix (letters then digits,
--   lower-cased), else a ConfigError; base URL https://<dc>.api.mailchimp.com/3.0
--   unless base_url is given (trimmed of trailing slashes) (glue/mailchimp.lua).
-- - protocol.ts: Basic anystring:<key>; failures are problem documents: detail | title,
--   plus " (field: message; ...)" for `errors`.
-- - errors.ts: UnknownMailchimpError, MailchimpParseError.
--
-- The transactional model (Mandrill: the key as a `key` body member from
-- MAILCHIMP_TRANSACTIONAL_API_KEY | MANDRILL_API_KEY, https://mandrillapp.com/api/1.0,
-- { status = "error", name, message } failures) needs task 10's per-model override once
-- it covers auth and options, and a transform_input glue.
-- Not mirrored: MailchimpApiError (the unknown error with a problem message) and the
-- unknown error's type, title and instance fields.
return {
  name = "mailchimp",
  title = "Mailchimp",
  base_url = {
    default = "https://{server_prefix}.api.mailchimp.com/3.0",
    option = "base_url",
    trim_slash = true,
  },
  options = {
    api_key = { secret = true, env = "MAILCHIMP_API_KEY", required = true },
    server_prefix = { env = "MAILCHIMP_SERVER_PREFIX", doc = "data centre, e.g. us21" },
  },
  headers = { Authorization = { basic = "anystring:{api_key}" } },
  glue = "glue/mailchimp.lua",
  unknown_tag = "UnknownMailchimpError",
  parse_tag = "MailchimpParseError",
}
