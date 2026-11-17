-- Scaleway's provider spec (98 models, one per product API and version: instance_v1,
-- k8s_v1, rdb_v1, ...).
--
-- Mirrors Distilled's hand-written Scaleway glue (packages/scaleway/src/):
-- - credentials.ts: the secret key from SCW_SECRET_KEY, sent as X-Auth-Token; the
--   default region from SCW_DEFAULT_REGION (fr-par) and zone from SCW_DEFAULT_ZONE
--   (fr-par-1); SCW_DEFAULT_ORGANIZATION_ID and SCW_DEFAULT_PROJECT_ID for callers
--   building requests; SCW_API_URL replaces https://api.scaleway.com (trailing slashes
--   trimmed) for the operations on that host only.
-- - protocol.ts: each operation's host is its smithy.api#http baseUrl (task 12):
--   https://api.scaleway.com, or https://api.scaleway.ai for Generative APIs, which also
--   take Authorization: Bearer; missing {region} / {zone} labels from the options;
--   nulls dropped and X-Total-Count folded into total_count; `...Raw` downloads ask
--   for the file with dl=1 (rest.lua, op.raw_download); failures by body.type
--   (glue/scaleway.lua).
-- - errors.ts: InvalidArgumentsError, DeniedAuthenticationError, PermissionsDeniedError,
--   QuotasExceededError, ResourceNotFoundError, ResourceExpiredError, ResourceLockedError,
--   TransientStateError (retryable), AlreadyExistsError, PreconditionFailedError,
--   OutOfStockError, UnknownScalewayError, ScalewayParseError.
-- - pagination.ts: page lists stop by total_count (paginateByTotalCount: the pages are
--   sized by the first one), token lists by next_page_token.
-- Not mirrored: a success body is JSON whenever it parses (Distilled reads it as text
-- unless the Content-Type says JSON; Instance user data is text/plain).
return {
  name = "scaleway",
  title = "Scaleway",
  base_url = {
    default = "https://api.scaleway.com",
    option = "base_url",
    env = "SCW_API_URL",
    trim_slash = true,
  },
  auth = { kind = "header", header = "X-Auth-Token", from = "secret_key", env = "SCW_SECRET_KEY" },
  options = {
    region = { env = "SCW_DEFAULT_REGION", default = "fr-par", doc = "fills a missing {region}" },
    zone = { env = "SCW_DEFAULT_ZONE", default = "fr-par-1", doc = "fills a missing {zone}" },
    organization_id = { env = "SCW_DEFAULT_ORGANIZATION_ID", doc = "for callers building requests" },
    project_id = { env = "SCW_DEFAULT_PROJECT_ID", doc = "for callers building requests" },
  },
  pagination = { modes = { page = "total_count" } },
  glue = "glue/scaleway.lua",
  unknown_tag = "UnknownScalewayError",
  parse_tag = "ScalewayParseError",
}
