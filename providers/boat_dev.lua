-- Boat's provider spec (package boat-dev).
--
-- Mirrors Distilled's hand-written Boat glue (packages/boat-dev/src/):
-- - credentials.ts: the key from BOAT_API_KEY; the base URL from BOAT_API_BASE_URL, else
--   BOAT_API_BASE, default https://boat.dev/api/v1; the organization from BOAT_ORG.
-- - protocol.ts: bearer auth; X-Boat-Org when an organization is set.
-- - errors.ts: UnknownBoatError, BoatParseError.
return {
  name = "boat_dev",
  title = "Boat",
  base_url = {
    default = "https://boat.dev/api/v1",
    option = "base_url",
    env = { "BOAT_API_BASE_URL", "BOAT_API_BASE" },
  },
  auth = { kind = "bearer", from = "api_key", env = "BOAT_API_KEY" },
  options = { org = { env = "BOAT_ORG", doc = "organization (X-Boat-Org)" } },
  headers = { ["X-Boat-Org"] = "{org}" },
  -- Boat streams application/x-ndjson (Distilled: `streams: true`, `framing: T.ndjson`):
  -- attach_command_stream, and execute_sandbox_command_stream (stream = true)
  stream_framing = "ndjson",
  unknown_tag = "UnknownBoatError",
  parse_tag = "BoatParseError",
}
