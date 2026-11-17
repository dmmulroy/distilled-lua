-- E2B's provider spec (16 models; the control-plane API).
--
-- Mirrors Distilled's hand-written E2B glue (packages/e2b/src/):
-- - credentials.ts: X-API-Key from E2B_API_KEY and/or a bearer access token from
--   E2B_ACCESS_TOKEN (one is required); the team from E2B_TEAM_ID; the base URL from
--   E2B_API_URL, else https://api.{domain} with E2B_DOMAIN, default e2b.app.
-- - protocol.ts: X-API-Key, Authorization: Bearer and X-Team-ID when set.
-- - errors.ts: UnknownE2BError, E2BParseError.
--
-- The envd models (per-sandbox connection: https://{port}-{sandboxId}.{domain},
-- E2b-Sandbox-Id / E2b-Sandbox-Port / X-Access-Token headers, empty JSON bodies) and the
-- volume model (a volume token) need task 10's per-model override once it covers auth
-- and options.
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
  unknown_tag = "UnknownE2BError",
  parse_tag = "E2BParseError",
}
