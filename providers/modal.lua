-- Modal's provider spec (task 23): 40 proto3 models (one per RPC prefix of
-- modal.client.ModalClient, plus the task command router), served as binary gRPC.
--
-- Mirrors Distilled's hand-written Modal glue (packages/modal/src/):
-- - protocol.ts: core's gRPC protocol over plain HTTP/1.1 (Modal's envoy bridges it to
--   gRPC), every operation one `application/grpc` frame transcoded with
--   src/descriptors.ts. Headers: `x-modal-token-id` / `x-modal-token-secret` (skipped
--   when the token id is "", Distilled's `anonymous()` for the token flow),
--   `x-modal-auth-token` when set, or `authorization: Bearer <jwt>` instead of all of
--   them for a sandbox's task command router (`withTaskCommandRouter`, which also goes
--   over HTTP/2); always `x-modal-client-type: 8` (CLIENT_TYPE_LIBMODAL_JS),
--   `x-modal-client-version: 1.6.3` and `x-modal-libmodal-version: modal-js/0.11.1`.
--   The error envelope reads `message`, else `details`, and `code`.
-- - credentials.ts: MODAL_TOKEN_ID and MODAL_TOKEN_SECRET (required), the base URL from
--   MODAL_SERVER_URL, else MODAL_API_URL, default https://api.modal.com.
-- - errors.ts: UnknownModalError, ModalParseError.
-- - scripts/generate.ts: error matchers on the patched error shapes are the
--   `com.modal.protocols#errorMatchers` trait (they key on the numeric gRPC code); wire
--   names are the surface; server-streaming RPCs are callable (collected into { items }).
--
-- Not ported: `fromContainer` (calls over the container's unix socket, MODAL_SERVER_URL
-- = unix:...; curl could, the transport contract has no socket path), the
-- `x-modal-auth-token` fetch and cache (`withAuthToken`: pass auth_token yourself) and
-- `.stream` (incremental server streams).
return {
  name = "modal",
  title = "Modal",
  base_url = { default = "https://api.modal.com", option = "base_url", env = "MODAL_SERVER_URL" },
  auth = { kind = "none" },
  unknown_tag = "UnknownModalError",
  parse_tag = "ModalParseError",
  naming = { members = "wire" },
  rpc = {
    wire = "grpc",
    descriptors = "descriptors.ts",
    error_matchers_trait = "com.modal.protocols#errorMatchers",
    http2 = "bearer_token",
    options = {
      token_id = {
        secret = true,
        env = "MODAL_TOKEN_ID",
        required = true,
        doc = 'the token id ("" for the anonymous token flow)',
      },
      token_secret = { secret = true, env = "MODAL_TOKEN_SECRET", required = true },
      auth_token = { secret = true, doc = "sent as x-modal-auth-token (V2 sandbox RPCs)" },
      bearer_token = {
        secret = true,
        doc = "a task command router's JWT: sent as the bearer instead of the token pair, "
          .. "over HTTP/2 (set base_url to the router's URL)",
      },
      base_url = {
        env = { "MODAL_SERVER_URL", "MODAL_API_URL" },
        default = "https://api.modal.com",
      },
    },
    headers = {
      { "authorization", "Bearer {bearer_token}" },
      { "x-modal-token-id", "{token_id}", unless = "bearer_token" },
      { "x-modal-token-secret", "{token_secret}", unless = "bearer_token" },
      { "x-modal-auth-token", "{auth_token}", unless = "bearer_token" },
      { "x-modal-client-type", "8" },
      { "x-modal-client-version", "1.6.3" },
      { "x-modal-libmodal-version", "modal-js/0.11.1" },
    },
    error_envelope = { code = "/code", message = { "/message", "/details" } },
  },
}
