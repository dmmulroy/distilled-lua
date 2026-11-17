-- ApacheSuperset's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written ApacheSuperset glue (packages/apache-superset/src/):
-- - credentials.ts: the key from SUPERSET_ACCESS_TOKEN; the base URL from SUPERSET_URL,
--   default http://localhost:8088.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownApacheSupersetError, ApacheSupersetParseError.
return {
  name = "apache_superset",
  title = "ApacheSuperset",
  base_url = {
    default = "http://localhost:8088",
    option = "base_url",
    env = "SUPERSET_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "SUPERSET_ACCESS_TOKEN" },
  unknown_tag = "UnknownApacheSupersetError",
  parse_tag = "ApacheSupersetParseError",
}
