-- Hostinger's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Hostinger glue (packages/hostinger/src/):
-- - credentials.ts: the key from HOSTINGER_API_KEY; the base URL from HOSTINGER_API_BASE_URL,
--   default https://developers.hostinger.com.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownHostingerError, HostingerParseError.
return {
  name = "hostinger",
  title = "Hostinger",
  base_url = {
    default = "https://developers.hostinger.com",
    option = "base_url",
    env = "HOSTINGER_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "HOSTINGER_API_KEY" },
  unknown_tag = "UnknownHostingerError",
  parse_tag = "HostingerParseError",
}
