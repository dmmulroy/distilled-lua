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
-- The functions model needs task 10's per-model override, once it covers auth and
-- options: Basic <user>:<secret>, the apiHost option (no environment variable, no
-- default), failures { error }.
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
  unknown_tag = "UnknownDigitalOceanError",
  parse_tag = "DigitalOceanParseError",
}
