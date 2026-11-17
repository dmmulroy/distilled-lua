-- Typesense's provider spec.
--
-- Mirrors Distilled's hand-written Typesense glue (packages/typesense/src/):
-- - credentials.ts: the key from TYPESENSE_API_KEY; the server from TYPESENSE_API_URL
--   (required, no default).
-- - protocol.ts: an X-TYPESENSE-API-KEY header (formatHeaders).
-- - errors.ts: UnknownTypesenseError, TypesenseParseError.
return {
  name = "typesense",
  title = "Typesense",
  base_url = { option = "base_url", env = "TYPESENSE_API_URL" },
  auth = {
    kind = "header",
    header = "X-TYPESENSE-API-KEY",
    from = "api_key",
    env = "TYPESENSE_API_KEY",
  },
  unknown_tag = "UnknownTypesenseError",
  parse_tag = "TypesenseParseError",
}
