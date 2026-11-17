-- Prisma's provider spec.
--
-- Mirrors Distilled's hand-written Prisma glue (packages/prisma/src/):
-- - credentials.ts: the token from PRISMA_API_TOKEN, else PRISMA_POSTGRES_API_TOKEN;
--   base URL https://api.prisma.io (an option only).
-- - protocol.ts: bearer auth; failures are { error = { code, message, hint } }; the
--   unknown error carries the hint.
-- - errors.ts: UnknownPrismaError, PrismaParseError.
return {
  name = "prisma",
  title = "Prisma",
  base_url = { default = "https://api.prisma.io", option = "base_url" },
  auth = {
    kind = "bearer",
    from = "api_token",
    env = { "PRISMA_API_TOKEN", "PRISMA_POSTGRES_API_TOKEN" },
  },
  error_envelope = { code = "/error/code", message = "/error/message" },
  unknown_fields = { hint = "/error/hint" },
  unknown_tag = "UnknownPrismaError",
  parse_tag = "PrismaParseError",
}
