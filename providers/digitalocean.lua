-- DigitalOcean's provider spec (models digitalocean and functions).
--
-- Mirrors Distilled's hand-written DigitalOcean glue (packages/digitalocean/src/):
-- - credentials.ts (model digitalocean): the token from DIGITALOCEAN_TOKEN, else
--   DIGITALOCEAN_ACCESS_TOKEN, else DIGITALOCEAN_API_KEY; the base URL from
--   DIGITALOCEAN_API_BASE_URL, default https://api.digitalocean.com; the inference and
--   actions servers default to https://inference.do-ai.run and https://actions.do-ai.run
--   (options only).
-- - protocol.ts: bearer auth, Content-Type JSON; an operation's server picks its base
--   URL (glue/digitalocean.lua: route.server, task 12); failures are { id | code,
--   message }.
-- - errors.ts: UnknownDigitalOceanError, DigitalOceanParseError.
--
-- - functions.ts / protocol.ts FunctionsProtocol (model functions, one namespace's
--   OpenWhisk API): Basic <user>:<secret> (FunctionsConfig user, secret), the base URL
--   is the namespace's api_host (no environment variable, no default), failures
--   { error, code } where code is a request id (message = error only).
return {
  name = "digitalocean",
  title = "DigitalOcean",
  base_url = {
    default = "https://api.digitalocean.com",
    option = "base_url",
    env = "DIGITALOCEAN_API_BASE_URL",
  },
  auth = {
    kind = "bearer",
    from = "api_key",
    env = { "DIGITALOCEAN_TOKEN", "DIGITALOCEAN_ACCESS_TOKEN", "DIGITALOCEAN_API_KEY" },
  },
  options = {
    inference_base_url = { default = "https://inference.do-ai.run" },
    actions_base_url = { default = "https://actions.do-ai.run" },
  },
  error_envelope = { code = { "/id", "/code" }, message = "/message" },
  glue = "glue/digitalocean.lua",
  models = {
    override = {
      functions = {
        base_url = { default = false, option = "api_host", env = false },
        auth = { kind = "basic", username = "user", password = "secret" },
        options = {
          user = { required = true, doc = "access key id, or the namespace uuid" },
          secret = {
            secret = true,
            required = true,
            doc = "access key secret, or the namespace key",
          },
        },
        error_envelope = { message = "/error" },
        glue = false,
      },
    },
  },
  unknown_tag = "UnknownDigitalOceanError",
  parse_tag = "DigitalOceanParseError",
}
