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
-- - credentials.ts / protocol.ts (Transactional API, formerly Mandrill, model
--   transactional): the key from MAILCHIMP_TRANSACTIONAL_API_KEY, else MANDRILL_API_KEY,
--   sent as the `key` body member of every call; base URL
--   https://mandrillapp.com/api/1.0 (trimmed); failures { status = "error", code, name,
--   message } read as "name: message", MailchimpTransactionalError for a status nothing
--   else maps (glue/mailchimp_transactional.lua).
-- - errors.ts: a problem document nothing else maps is MailchimpApiError, any other
--   failure UnknownMailchimpError, both with the problem's type, title and instance.
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
  models = {
    override = {
      transactional = {
        base_url = { default = "https://mandrillapp.com/api/1.0" },
        options = {
          api_key = {
            secret = true,
            env = { "MAILCHIMP_TRANSACTIONAL_API_KEY", "MANDRILL_API_KEY" },
            required = true,
          },
        },
        headers = false,
        glue = "glue/mailchimp_transactional.lua",
      },
    },
  },
  unknown_tag = "UnknownMailchimpError",
  parse_tag = "MailchimpParseError",
}
