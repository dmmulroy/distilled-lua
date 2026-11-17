-- boxd's provider spec (task 23): a proto3 model served as gRPC-Web.
--
-- Mirrors Distilled's hand-written boxd glue (packages/boxd/src/):
-- - protocol.ts: core's gRPC protocol with `web: true` (tonic-web answers gRPC-Web over
--   HTTP/1.1, and refuses JSON and plain application/grpc there), so every operation is
--   one `application/grpc-web+proto` frame, transcoded with src/descriptors.ts; auth is
--   `authorization: Bearer <API key or token>`; the error envelope is `{ code, message }`
--   (the default one).
-- - credentials.ts: the token from BOXD_API_KEY, else BOXD_TOKEN; the endpoint from
--   BOXD_BASE_URL, else BOXD_API_URL, default https://boxd.sh:9443.
-- - errors.ts: UnknownBoxdError, BoxdParseError.
-- - scripts/generate.ts: wire names (proto3 JSON camelCase) are the surface;
--   server-streaming RPCs are callable (here: the stream is collected into { items }).
return {
  name = "boxd",
  title = "Boxd",
  base_url = { default = "https://boxd.sh:9443", option = "base_url", env = "BOXD_BASE_URL" },
  auth = { kind = "bearer", from = "token", env = "BOXD_API_KEY" },
  unknown_tag = "UnknownBoxdError",
  parse_tag = "BoxdParseError",
  naming = { members = "wire" },
  proto = {
    wire = "grpc-web",
    descriptors = "descriptors.ts",
    options = {
      token = {
        secret = true,
        env = { "BOXD_API_KEY", "BOXD_TOKEN" },
        required = true,
        doc = "an API key (bxd_...) or a session token, sent as the bearer",
      },
      base_url = {
        env = { "BOXD_BASE_URL", "BOXD_API_URL" },
        default = "https://boxd.sh:9443",
      },
    },
  },
}
