-- Auth0's provider spec.
--
-- Mirrors Distilled's hand-written Auth0 glue (packages/auth0/src/):
-- - credentials.ts: the management token from AUTH0_MANAGEMENT_TOKEN; the tenant domain
--   from AUTH0_DOMAIN (scheme and trailing slashes removed: apiBaseUrlForDomain), base
--   URL https://{domain}/api/v2 unless AUTH0_API_BASE_URL gives it. Both are required.
-- - protocol.ts: bearer auth, the default envelope.
-- - errors.ts: UnknownAuth0Error, Auth0ParseError.
return {
  name = "auth0",
  title = "Auth0",
  base_url = {
    default = "https://{domain}/api/v2",
    option = "base_url",
    env = "AUTH0_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "token", env = "AUTH0_MANAGEMENT_TOKEN" },
  options = {
    domain = {
      env = "AUTH0_DOMAIN",
      strip_scheme = true,
      trim_slash = true,
      doc = "tenant domain, e.g. acme.eu.auth0.com",
    },
  },
  unknown_tag = "UnknownAuth0Error",
  parse_tag = "Auth0ParseError",
}
