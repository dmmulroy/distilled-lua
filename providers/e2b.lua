-- E2B's provider spec (16 models; the control-plane API).
--
-- Mirrors Distilled's hand-written E2B glue (packages/e2b/src/):
-- - credentials.ts: X-API-Key from E2B_API_KEY and/or a bearer access token from
--   E2B_ACCESS_TOKEN (one is required); the team from E2B_TEAM_ID; the base URL from
--   E2B_API_URL, else https://api.{domain} with E2B_DOMAIN, default e2b.app.
-- - protocol.ts: X-API-Key, Authorization: Bearer and X-Team-ID when set.
-- - errors.ts: UnknownE2BError, E2BParseError.
--
-- - protocol.ts EnvdProtocol (models envd, filesystem, process: one sandbox, the
--   SandboxConnection): E2b-Sandbox-Id, E2b-Sandbox-Port (default 49983),
--   Connect-Protocol-Version 1 and the envd access token as X-Access-Token; host
--   https://sandbox.<domain> on E2B Cloud, else https://<port>-<sandbox_id>.<domain>
--   (glue/e2b_envd.lua); {} for a bodied call without body members (emptyJsonBody).
--   The Connect streaming parts are task 23's.
-- - protocol.ts VolumeContentProtocol (model volume_content: one volume, the
--   VolumeConnection): bearer volume token, https://api.<domain>.
-- the three envd models share one connection (EnvdProtocol)
local ENVD = {
  base_url = { default = "https://sandbox.{domain}", env = false },
  auth = false,
  require_one_of = false,
  options = {
    sandbox_id = { required = true, doc = "the sandbox to address" },
    access_token = { secret = true, doc = "the sandbox's envdAccessToken" },
    domain = { default = "e2b.app", doc = "the sandbox's domain" },
    port = { default = "49983", doc = "envd's port" },
  },
  headers = {
    ["E2b-Sandbox-Id"] = "{sandbox_id}",
    ["E2b-Sandbox-Port"] = "{port}",
    ["Connect-Protocol-Version"] = "1",
    ["X-Access-Token"] = "{access_token}",
  },
  empty_json_body = true,
  glue = "glue/e2b_envd.lua",
}

return {
  name = "e2b",
  title = "E2B",
  base_url = { default = "https://api.{domain}", option = "base_url", env = "E2B_API_URL" },
  options = {
    api_key = { secret = true, env = "E2B_API_KEY" },
    access_token = { secret = true, env = "E2B_ACCESS_TOKEN" },
    team_id = { env = "E2B_TEAM_ID" },
    domain = { env = "E2B_DOMAIN", default = "e2b.app" },
  },
  require_one_of = { "api_key", "access_token" },
  headers = {
    ["X-API-Key"] = "{api_key}",
    Authorization = "Bearer {access_token}",
    ["X-Team-ID"] = "{team_id}",
  },
  models = {
    override = {
      envd = ENVD,
      filesystem = ENVD,
      process = ENVD,
      volume_content = {
        base_url = { default = "https://api.{domain}", env = false },
        auth = { kind = "bearer", from = "token" },
        require_one_of = false,
        options = { domain = { default = "e2b.app", doc = "the volume's domain" } },
        headers = false,
      },
    },
  },
  unknown_tag = "UnknownE2BError",
  parse_tag = "E2BParseError",
}
