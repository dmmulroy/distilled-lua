-- Fly.io's provider spec (models machines, mpg and sprites).
--
-- Mirrors Distilled's hand-written Fly.io glue (packages/fly-io/src/):
-- - credentials.ts (Machines API): the token from FLY_API_TOKEN, else FLY_IO_API_KEY;
--   the host from FLY_API_HOSTNAME, default https://api.machines.dev, trimmed of
--   trailing slashes and of a trailing /v1 (normalizeApiBaseUrl, glue/fly_io.lua).
-- - protocol.ts: bearer auth; failures are { error | message | errors.detail }.
-- - errors.ts: UnknownFlyIoError, FlyIoParseError.
--
-- Needs task 10's per-model override: mpg uses https://api.fly.io (DEFAULT_FLY_API_BASE_URL);
-- sprites (https://api.sprites.dev/v1, "FlyV1 <macaroon>" auth, NDJSON bodies) is class C.
-- Not mirrored: MachineIdentity (drops auth inside a Machine).
return {
  name = "fly_io",
  title = "FlyIo",
  base_url = {
    default = "https://api.machines.dev",
    option = "base_url",
    env = "FLY_API_HOSTNAME",
  },
  auth = { kind = "bearer", from = "api_key", env = { "FLY_API_TOKEN", "FLY_IO_API_KEY" } },
  error_envelope = { message = { "/error", "/message", "/errors/detail" } },
  glue = "glue/fly_io.lua",
  unknown_tag = "UnknownFlyIoError",
  parse_tag = "FlyIoParseError",
}
