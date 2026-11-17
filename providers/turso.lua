-- Turso's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Turso glue (packages/turso/src/):
-- - credentials.ts: the key from TURSO_API_KEY; the base URL from the option only,
--   default https://api.turso.tech.
-- - protocol.ts: bearer auth; the default { code, message } envelope; the base URL is an option only (no environment variable).
-- - errors.ts: UnknownTursoError, TursoParseError.
return {
  name = "turso",
  title = "Turso",
  base_url = {
    default = "https://api.turso.tech",
    option = "base_url",
  },
  auth = { kind = "bearer", from = "api_key", env = "TURSO_API_KEY" },
  unknown_tag = "UnknownTursoError",
  parse_tag = "TursoParseError",
}
