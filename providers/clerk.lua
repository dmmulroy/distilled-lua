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
-- The platform model needs task 10's per-model override, once it covers auth and
-- options: bearer CLERK_PLATFORM_API_KEY, no Clerk-API-Version, base URL
-- CLERK_PLATFORM_API_URL default https://api.clerk.com with /v1 appended unless present.
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
  unknown_tag = "UnknownClerkError",
  parse_tag = "ClerkParseError",
}
