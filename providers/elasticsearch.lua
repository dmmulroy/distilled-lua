-- Elasticsearch's provider spec.
--
-- Mirrors Distilled's hand-written Elasticsearch glue (packages/elasticsearch/src/):
-- - credentials.ts: the key from ELASTICSEARCH_API_KEY; the base URL from
--   ELASTICSEARCH_API_BASE_URL, default http://localhost:9200.
-- - protocol.ts: Authorization "ApiKey <key>".
-- - errors.ts: UnknownElasticsearchError, ElasticsearchParseError.
return {
  name = "elasticsearch",
  title = "Elasticsearch",
  base_url = {
    default = "http://localhost:9200",
    option = "base_url",
    env = "ELASTICSEARCH_API_BASE_URL",
  },
  auth = {
    kind = "header",
    header = "Authorization",
    prefix = "ApiKey ",
    from = "api_key",
    env = "ELASTICSEARCH_API_KEY",
  },
  unknown_tag = "UnknownElasticsearchError",
  parse_tag = "ElasticsearchParseError",
}
