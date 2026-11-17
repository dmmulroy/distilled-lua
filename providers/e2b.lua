-- E2B's provider spec (task 23): 16 models (OpenAPI control plane, envd's OpenAPI and
-- Connect services, volume content), all plain JSON through distilled.protocol.connect.
--
-- Mirrors Distilled's hand-written E2B glue (packages/e2b/src/):
-- - protocol.ts: one REST protocol per host. The control plane sends `X-API-Key`
--   (E2B_API_KEY), `Authorization: Bearer` (E2B_ACCESS_TOKEN, for api_keys and auth) and
--   `X-Team-ID` (E2B_TEAM_ID) when set. envd (`envd`, `process`, `filesystem`) addresses
--   one sandbox: `E2b-Sandbox-Id`, `E2b-Sandbox-Port`, `Connect-Protocol-Version: 1`
--   and `X-Access-Token` (the sandbox's envd token), posting `{}` for an empty message
--   (envd answers a bodyless Connect call with 415); no team key. Volume content sends
--   the volume's own token as the bearer.
-- - credentials.ts: the domain from E2B_DOMAIN (default e2b.app); the control plane at
--   E2B_API_URL, else https://api.<domain>; envd at https://sandbox.<domain> on E2B
--   Cloud (the shared host routes by the headers), else https://<port>-<id>.<domain>;
--   one of the API key and the access token is required.
-- - errors.ts: UnknownE2BError, E2BParseError; `{ code, message }` bodies (the default
--   envelope); SandboxNotRunning (502 from envd) is a model patch.
-- - scripts/generate.ts: wire names are the surface.
--
-- Not ported: connect.ts (process.Start / process.Connect / filesystem.WatchDir, the
-- Connect server streams written by hand, not generated operations).
local envd = {
  options = {
    api_key = false,
    access_token = {
      secret = true,
      doc = "the sandbox's envd access token (envdAccessToken from create or connect)",
    },
    team_id = false,
    base_url = false,
    sandbox_id = { required = true, doc = "the sandbox to address" },
    envd_port = { default = "49983", doc = "envd's port inside the sandbox" },
  },
  base_url = {
    when = "domain",
    cases = { ["e2b.app"] = "https://sandbox.{domain}" },
    default = "https://{envd_port}-{sandbox_id}.{domain}",
  },
  headers = {
    { "e2b-sandbox-id", "{sandbox_id}" },
    { "e2b-sandbox-port", "{envd_port}" },
    { "connect-protocol-version", "1" },
    { "x-access-token", "{access_token}" },
  },
  require_one_of = false,
  empty_json_body = true,
}

return {
  name = "e2b",
  title = "E2B",
  base_url = { default = "https://api.e2b.app", option = "base_url", env = "E2B_API_URL" },
  auth = { kind = "none" },
  unknown_tag = "UnknownE2BError",
  parse_tag = "E2BParseError",
  naming = { members = "wire" },
  rpc = {
    wire = "connect",
    options = {
      api_key = { secret = true, env = "E2B_API_KEY", doc = "the team API key (X-API-Key)" },
      access_token = {
        secret = true,
        env = "E2B_ACCESS_TOKEN",
        doc = "a personal access token (bearer), for api_keys and auth",
      },
      team_id = { env = "E2B_TEAM_ID", doc = "sent as X-Team-ID with the access token" },
      domain = { env = "E2B_DOMAIN", default = "e2b.app" },
      base_url = { env = "E2B_API_URL", default = "https://api.{domain}" },
    },
    headers = {
      { "x-api-key", "{api_key}" },
      { "authorization", "Bearer {access_token}" },
      { "x-team-id", "{team_id}" },
    },
    require_one_of = { "api_key", "access_token" },
    models = {
      envd = envd,
      process = envd,
      filesystem = envd,
      volume_content = {
        options = {
          api_key = false,
          access_token = false,
          team_id = false,
          base_url = false,
          token = {
            secret = true,
            required = true,
            doc = "the volume's content token (token from volumes.getVolume)",
          },
        },
        base_url = "https://api.{domain}",
        headers = { { "authorization", "Bearer {token}" } },
        require_one_of = false,
      },
    },
  },
}
