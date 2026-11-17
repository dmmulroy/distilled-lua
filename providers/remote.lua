-- Remote's provider spec.
--
-- Mirrors Distilled's hand-written Remote glue (packages/remote/src/):
-- - credentials.ts: the key from REMOTE_API_KEY, else REMOTE_ACCESS_TOKEN; the base URL
--   from REMOTE_API_BASE_URL, default https://gateway.remote.com.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownRemoteError, RemoteParseError.
return {
  name = "remote",
  title = "Remote",
  base_url = {
    default = "https://gateway.remote.com",
    option = "base_url",
    env = "REMOTE_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = { "REMOTE_API_KEY", "REMOTE_ACCESS_TOKEN" } },
  unknown_tag = "UnknownRemoteError",
  parse_tag = "RemoteParseError",
}
