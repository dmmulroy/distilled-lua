-- OpenSearch's provider spec (the bearer, basic and anonymous paths).
--
-- Mirrors Distilled's hand-written OpenSearch glue (packages/opensearch/src/):
-- - credentials.ts: OPENSEARCH_TOKEN (bearer), else OPENSEARCH_USERNAME and
--   OPENSEARCH_PASSWORD (Basic), else no auth; the URL from OPENSEARCH_URL, default
--   http://localhost:9200.
-- - protocol.ts: failures are { error = { type, reason } }, { error = text } or
--   { message }.
-- - errors.ts: UnknownOpenSearchError, OpenSearchParseError.
--
-- Not mirrored: OPENSEARCH_AWS_SERVICE (es | aoss) SigV4 signing (task 14).
return {
  name = "opensearch",
  title = "OpenSearch",
  base_url = { default = "http://localhost:9200", option = "base_url", env = "OPENSEARCH_URL" },
  options = {
    token = { secret = true, env = "OPENSEARCH_TOKEN" },
    username = { env = "OPENSEARCH_USERNAME" },
    password = { secret = true, env = "OPENSEARCH_PASSWORD" },
  },
  headers = { Authorization = { "Bearer {token}", { basic = "{username}:{password}" } } },
  error_envelope = {
    code = "/error/type",
    message = { "/error/reason", "/error", "/message" },
  },
  unknown_tag = "UnknownOpenSearchError",
  parse_tag = "OpenSearchParseError",
}
