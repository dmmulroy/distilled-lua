-- Surrealdb's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Surrealdb glue (packages/surrealdb/src/):
-- - credentials.ts: the key from SURREALDB_API_KEY; the base URL from SURREALDB_API_BASE_URL,
--   default http://127.0.0.1:8000.
-- - protocol.ts: bearer auth; the default { code, message } envelope; Accept: application/json (the runtime sends it).
-- - errors.ts: UnknownSurrealdbError, SurrealdbParseError.
return {
  name = "surrealdb",
  title = "Surrealdb",
  base_url = {
    default = "http://127.0.0.1:8000",
    option = "base_url",
    env = "SURREALDB_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "SURREALDB_API_KEY" },
  unknown_tag = "UnknownSurrealdbError",
  parse_tag = "SurrealdbParseError",
}
