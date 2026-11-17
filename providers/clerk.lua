-- Clerk's provider spec (models clerk and platform).
--
-- Mirrors Distilled's hand-written Clerk glue (packages/clerk/src/):
-- - credentials.ts (Backend API, model clerk): the key from CLERK_SECRET_KEY; the API
--   version from CLERK_API_VERSION, default 2026-05-12; the base URL from
--   CLERK_API_BASE_URL, default https://api.clerk.com/v1.
-- - protocol.ts: bearer auth, Clerk-API-Version; failures are
--   { errors = [{ code, message | long_message }] } or { code, message }.
-- - errors.ts: UnknownClerkError, ClerkParseError.
--
-- - credentials.ts / protocol.ts (Platform API, model platform: PlatformCredentials,
--   ClerkPlatformProtocol): bearer CLERK_PLATFORM_API_KEY, no Clerk-API-Version; the base
--   URL from CLERK_PLATFORM_API_URL, default https://api.clerk.com, trimmed of trailing
--   slashes, with /v1 appended unless it ends with /v1 (models.override.platform).
return {
  name = "clerk",
  title = "Clerk",
  base_url = {
    default = "https://api.clerk.com/v1",
    option = "base_url",
    env = "CLERK_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "CLERK_SECRET_KEY" },
  options = { api_version = { env = "CLERK_API_VERSION", default = "2026-05-12" } },
  headers = { ["Clerk-API-Version"] = "{api_version}" },
  error_envelope = {
    code = { "/errors/0/code", "/code" },
    message = { "/errors/0/message", "/errors/0/long_message", "/message" },
  },
  models = {
    override = {
      platform = {
        base_url = {
          default = "https://api.clerk.com",
          env = "CLERK_PLATFORM_API_URL",
          ensure_suffix = "/v1",
        },
        auth = { kind = "bearer", from = "api_key", env = "CLERK_PLATFORM_API_KEY" },
        options = false,
        headers = false,
      },
    },
  },
  unknown_tag = "UnknownClerkError",
  parse_tag = "ClerkParseError",
}
