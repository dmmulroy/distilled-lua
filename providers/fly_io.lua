-- Fly.io's provider spec (models machines, mpg and sprites).
--
-- Mirrors Distilled's hand-written Fly.io glue (packages/fly-io/src/):
-- - credentials.ts (Machines API): the token from FLY_API_TOKEN, else FLY_IO_API_KEY;
--   the host from FLY_API_HOSTNAME, default https://api.machines.dev, trimmed of
--   trailing slashes and of a trailing /v1 (normalizeApiBaseUrl, glue/fly_io.lua).
-- - protocol.ts: bearer auth; failures are { error | message | errors.detail }.
-- - errors.ts: UnknownFlyIoError, FlyIoParseError.
--
-- - protocol.ts FlyApiProtocol (model mpg): the same token, the fixed host
--   https://api.fly.io (DEFAULT_FLY_API_BASE_URL, no environment variable).
-- - protocol.ts SpritesProtocol (model sprites): https://api.sprites.dev/v1 with a bearer
--   token minted from the Fly token (organization from /v1/tokens/current on the
--   Machines host, else GraphQL; then POST /organizations/<slug>/tokens with
--   "FlyV1 <macaroon>", which the mint operation itself uses too); exec-frame and NDJSON
--   answers; SpritesNotEnabled (glue/fly_io_sprites.lua).
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
  models = {
    override = {
      mpg = {
        base_url = { default = "https://api.fly.io", env = false },
        glue = false,
      },
      sprites = {
        base_url = { default = "https://api.sprites.dev/v1", env = false },
        options = {
          machines_base_url = {
            env = "FLY_API_HOSTNAME",
            default = "https://api.machines.dev",
            doc = "the Machines API host (organization discovery for the token mint)",
          },
        },
        error_envelope = false,
        glue = "glue/fly_io_sprites.lua",
      },
    },
  },
  unknown_tag = "UnknownFlyIoError",
  parse_tag = "FlyIoParseError",
}
