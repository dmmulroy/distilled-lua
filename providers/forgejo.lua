-- Forgejo's provider spec.
--
-- Mirrors Distilled's hand-written Forgejo glue (packages/forgejo/src/):
-- - credentials.ts: the token from FORGEJO_TOKEN; the instance URL from FORGEJO_URL
--   (required), trailing slashes removed and /api/v1 appended unless present.
-- - protocol.ts: Authorization "token <token>", Accept JSON; failures are { message }.
-- - errors.ts: UnknownForgejoError, ForgejoParseError.
return {
  name = "forgejo",
  title = "Forgejo",
  base_url = { option = "base_url", env = "FORGEJO_URL", ensure_suffix = "/api/v1" },
  auth = {
    kind = "header",
    header = "Authorization",
    prefix = "token ",
    from = "token",
    env = "FORGEJO_TOKEN",
  },
  error_envelope = { message = "/message" },
  unknown_tag = "UnknownForgejoError",
  parse_tag = "ForgejoParseError",
}
