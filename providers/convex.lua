-- Convex's provider spec (models management, deployment and functions).
--
-- Mirrors Distilled's hand-written Convex glue (packages/convex/src/):
-- - credentials.ts (management model): the token from CONVEX_ACCESS_TOKEN; the base URL
--   from CONVEX_API_BASE_URL, default https://api.convex.dev/v1.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownConvexError, ConvexParseError.
--
-- The deployment and functions models need task 10's per-model override, once it
-- covers auth and options: Authorization "Convex <deploy key>" and base URL
-- <deploymentUrl>/api/v1 (deployment), no auth and <deploymentUrl>/api (functions);
-- deploymentUrl has no environment variable and is trimmed of trailing slashes.
return {
  name = "convex",
  title = "Convex",
  base_url = {
    default = "https://api.convex.dev/v1",
    option = "base_url",
    env = "CONVEX_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "access_token", env = "CONVEX_ACCESS_TOKEN" },
  unknown_tag = "UnknownConvexError",
  parse_tag = "ConvexParseError",
}
