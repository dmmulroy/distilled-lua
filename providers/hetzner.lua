-- Hetzner Cloud's provider spec: one spec for the package's 30 models (one module per
-- API tag, `require("hetzner.servers")`, as Distilled's one TS module per tag).
--
-- Mirrors Distilled's hand-written Hetzner glue (packages/hetzner/src/):
-- - credentials.ts: a bearer token from HCLOUD_TOKEN, the base URL from HCLOUD_ENDPOINT,
--   default https://api.hetzner.cloud/v1 (the API version is a path segment of the base
--   URL, so operations carry version-less routes).
-- - protocol.ts: failures are enveloped as { error = { code, message, details } }.
-- - errors.ts: UnknownHetznerError, HetznerParseError.
-- - scripts/generate.ts: wire member names are the surface (snake_case already).
--
-- Not expressible in a provider spec yet (task 13), so they differ from Distilled:
-- - statusMap 405 MethodNotAllowed, 410 Gone, 412 PreconditionFailed: hand-written error
--   classes the model does not declare. Those statuses surface as UnknownHetznerError.
-- - UnknownHetznerError's `details` field (the envelope's error.details).
return {
  name = "hetzner",
  title = "Hetzner",
  base_url = {
    default = "https://api.hetzner.cloud/v1",
    option = "base_url",
    env = "HCLOUD_ENDPOINT",
  },
  auth = { kind = "bearer", from = "token", env = "HCLOUD_TOKEN" },
  unknown_tag = "UnknownHetznerError",
  parse_tag = "HetznerParseError",
  error_envelope = { code = "/error/code", message = "/error/message" },
  naming = { members = "wire" },
}
