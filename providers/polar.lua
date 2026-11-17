-- Polar's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Polar glue (packages/polar/src/):
-- - credentials.ts: the key from POLAR_API_KEY; the base URL from POLAR_API_BASE_URL,
--   default https://api.polar.sh.
-- - protocol.ts: bearer auth; the default { code, message } envelope. pagination.ts (paginatePolar, page numbers) is task 12's.
-- - errors.ts: UnknownPolarError, PolarParseError.
return {
  name = "polar",
  title = "Polar",
  base_url = {
    default = "https://api.polar.sh",
    option = "base_url",
    env = "POLAR_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "POLAR_API_KEY" },
  unknown_tag = "UnknownPolarError",
  parse_tag = "PolarParseError",
}
