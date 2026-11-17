-- ClickHouse Cloud's provider spec.
--
-- Mirrors Distilled's hand-written ClickHouse Cloud glue (packages/clickhouse-cloud/src/):
-- - credentials.ts: the key id from CLICKHOUSE_CLOUD_API_KEY_ID and secret from
--   CLICKHOUSE_CLOUD_API_KEY_SECRET; the base URL from CLICKHOUSE_CLOUD_API_URL, default
--   https://api.clickhouse.cloud, trailing slashes removed.
-- - protocol.ts: HTTP Basic auth (key id : key secret); responses are { result } and
--   are unwrapped, except on paginated operations (ClickHouseCloudPaginatedProtocol
--   keeps the envelope for the cursor).
-- - errors.ts: UnknownClickHouseCloudError, ClickHouseCloudParseError.
return {
  name = "clickhouse_cloud",
  title = "ClickHouseCloud",
  base_url = {
    default = "https://api.clickhouse.cloud",
    option = "base_url",
    env = "CLICKHOUSE_CLOUD_API_URL",
    trim_slash = true,
  },
  auth = { kind = "basic", username = "key_id", password = "key_secret" },
  options = {
    key_id = { env = "CLICKHOUSE_CLOUD_API_KEY_ID", required = true, doc = "API key id" },
    key_secret = { secret = true, env = "CLICKHOUSE_CLOUD_API_KEY_SECRET", required = true },
  },
  transform_response = { { unwrap = "result", skip_paginated = true } },
  unknown_tag = "UnknownClickHouseCloudError",
  parse_tag = "ClickHouseCloudParseError",
}
