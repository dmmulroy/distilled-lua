-- npm's provider spec.
--
-- Mirrors Distilled's hand-written npm glue (packages/npm/src/):
-- - credentials.ts: an optional token from NPM_TOKEN; the registry from
--   NPM_API_BASE_URL, default https://registry.npmjs.org, trailing slashes removed.
-- - protocol.ts: bearer auth only when a token is set.
-- - errors.ts: UnknownNpmError, NpmParseError.
return {
  name = "npm",
  title = "Npm",
  base_url = {
    default = "https://registry.npmjs.org",
    option = "base_url",
    env = "NPM_API_BASE_URL",
    trim_slash = true,
  },
  auth = { kind = "bearer", from = "token", env = "NPM_TOKEN", optional = true },
  unknown_tag = "UnknownNpmError",
  parse_tag = "NpmParseError",
}
