-- Temporal's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Temporal glue (packages/temporal/src/):
-- - credentials.ts: the key from TEMPORAL_API_KEY; the base URL from TEMPORAL_API_BASE_URL,
--   default http://localhost:7243.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownTemporalError, TemporalParseError.
return {
  name = "temporal",
  title = "Temporal",
  base_url = {
    default = "http://localhost:7243",
    option = "base_url",
    env = "TEMPORAL_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "TEMPORAL_API_KEY" },
  unknown_tag = "UnknownTemporalError",
  parse_tag = "TemporalParseError",
}
