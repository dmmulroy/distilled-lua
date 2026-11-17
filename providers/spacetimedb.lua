-- SpacetimeDB's provider spec.
--
-- Mirrors Distilled's hand-written SpacetimeDB glue (packages/spacetimedb/src/):
-- - credentials.ts: an optional token from SPACETIMEDB_TOKEN, else SPACETIME_TOKEN
--   (fromAnonymous: none); the base URL from SPACETIMEDB_API_BASE_URL, else
--   SPACETIMEDB_HOST, else SPACETIME_HOST, default https://maincloud.spacetimedb.com.
-- - protocol.ts: bearer auth only when the token is not empty.
-- - errors.ts: UnknownSpacetimeDBError, SpacetimeDBParseError.
return {
  name = "spacetimedb",
  title = "SpacetimeDB",
  base_url = {
    default = "https://maincloud.spacetimedb.com",
    option = "base_url",
    env = { "SPACETIMEDB_API_BASE_URL", "SPACETIMEDB_HOST", "SPACETIME_HOST" },
  },
  auth = {
    kind = "bearer",
    from = "api_key",
    env = { "SPACETIMEDB_TOKEN", "SPACETIME_TOKEN" },
    optional = true,
  },
  unknown_tag = "UnknownSpacetimeDBError",
  parse_tag = "SpacetimeDBParseError",
}
