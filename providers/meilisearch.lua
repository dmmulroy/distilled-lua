-- Meilisearch's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Meilisearch glue (packages/meilisearch/src/):
-- - credentials.ts: the key from MEILISEARCH_API_KEY; the base URL from MEILISEARCH_API_BASE_URL,
--   default http://localhost:7700.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownMeilisearchError, MeilisearchParseError.
return {
  name = "meilisearch",
  title = "Meilisearch",
  base_url = {
    default = "http://localhost:7700",
    option = "base_url",
    env = "MEILISEARCH_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "MEILISEARCH_API_KEY" },
  unknown_tag = "UnknownMeilisearchError",
  parse_tag = "MeilisearchParseError",
}
