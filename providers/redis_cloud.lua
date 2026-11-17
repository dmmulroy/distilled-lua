-- Redis Cloud's provider spec.
--
-- Mirrors Distilled's hand-written Redis Cloud glue (packages/redis-cloud/src/):
-- - credentials.ts: the account key from REDIS_CLOUD_API_KEY, the user secret key from
--   REDIS_CLOUD_API_SECRET_KEY, an optional auth token from REDIS_CLOUD_AUTH_TOKEN; the
--   base URL from REDIS_CLOUD_API_BASE_URL, default https://api.redislabs.com.
-- - protocol.ts: x-api-key, x-api-secret-key and (when set) x-auth-token headers.
-- - errors.ts: UnknownRedisCloudError, RedisCloudParseError.
return {
  name = "redis_cloud",
  title = "RedisCloud",
  base_url = {
    default = "https://api.redislabs.com",
    option = "base_url",
    env = "REDIS_CLOUD_API_BASE_URL",
  },
  auth = { kind = "header", header = "x-api-key", from = "api_key", env = "REDIS_CLOUD_API_KEY" },
  options = {
    api_secret_key = { secret = true, env = "REDIS_CLOUD_API_SECRET_KEY", required = true },
    auth_token = { secret = true, env = "REDIS_CLOUD_AUTH_TOKEN" },
  },
  headers = { ["x-api-secret-key"] = "{api_secret_key}", ["x-auth-token"] = "{auth_token}" },
  unknown_tag = "UnknownRedisCloudError",
  parse_tag = "RedisCloudParseError",
}
