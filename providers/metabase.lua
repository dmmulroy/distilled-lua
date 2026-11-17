-- Metabase's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Metabase glue (packages/metabase/src/):
-- - credentials.ts: the key from METABASE_API_KEY; the base URL from METABASE_API_BASE_URL,
--   default http://localhost:3000.
-- - protocol.ts: an X-API-Key header; the default { code, message } envelope.
-- - errors.ts: UnknownMetabaseError, MetabaseParseError.
return {
  name = "metabase",
  title = "Metabase",
  base_url = {
    default = "http://localhost:3000",
    option = "base_url",
    env = "METABASE_API_BASE_URL",
  },
  auth = { kind = "header", header = "X-API-Key", from = "api_key", env = "METABASE_API_KEY" },
  unknown_tag = "UnknownMetabaseError",
  parse_tag = "MetabaseParseError",
}
