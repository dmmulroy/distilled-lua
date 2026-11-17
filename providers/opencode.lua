-- opencode server's provider spec.
--
-- Mirrors Distilled's hand-written opencode glue (packages/opencode/src/):
-- - credentials.ts: the username from OPENCODE_SERVER_USERNAME, default opencode; the
--   password from OPENCODE_SERVER_PASSWORD (optional); the base URL from
--   OPENCODE_API_BASE_URL, default http://127.0.0.1:4096.
-- - protocol.ts: HTTP Basic auth only when a password is set.
-- - errors.ts: UnknownOpencodeError, OpencodeParseError.
return {
  name = "opencode",
  title = "Opencode",
  base_url = {
    default = "http://127.0.0.1:4096",
    option = "base_url",
    env = "OPENCODE_API_BASE_URL",
  },
  auth = { kind = "basic", username = "username", password = "password" },
  options = {
    username = { env = "OPENCODE_SERVER_USERNAME", default = "opencode" },
    password = { secret = true, env = "OPENCODE_SERVER_PASSWORD" },
  },
  unknown_tag = "UnknownOpencodeError",
  parse_tag = "OpencodeParseError",
}
