-- Namespace's provider spec (task 23): 29 proto3 models (one per proto package), called
-- as Connect unary RPCs over JSON through distilled.protocol.connect.
--
-- Mirrors Distilled's hand-written Namespace glue (packages/namespacelabs/src/):
-- - protocol.ts: every RPC is `POST /<package>.<Service>/<Method>` with
--   `Authorization: Bearer <token>` and a JSON body (`{}` for an empty message), sent to
--   the host its proto package lives on (HOST_BY_PACKAGE_PREFIX): compute
--   (namespace.cloud.compute., namespace.cloud.builder., namespace.experimental.compute.),
--   storage (namespace.cloud.storage.), the private API (namespace.cloud.github.,
--   namespace.private.), else global. Connect error bodies are `{ code, message,
--   details? }`; the unknown error carries `details`.
-- - credentials.ts: NSC_TOKEN (required); NSC_REGION (default us); the compute host from
--   NSC_COMPUTE_URL, else NSC_ENDPOINT, default https://<region>.compute.namespaceapis.com;
--   NSC_STORAGE_URL (https://<region>.storage.namespaceapis.com), NSC_GLOBAL_URL
--   (https://global.namespaceapis.com), NSC_PRIVATE_API_URL
--   (https://private-api.global.namespaceapis.com).
-- - errors.ts: UnknownNamespaceLabsError, NamespaceLabsParseError.
-- - scripts/generate.ts: wire names are the surface.
--
-- Not ported: CredentialsFromTokenFile (NSC_TOKEN_FILE's bearer_token: read the file and
-- pass token = ... yourself).
local by_prefix = {
  { "/namespace.cloud.compute.", "{compute_base_url}" },
  { "/namespace.cloud.builder.", "{compute_base_url}" },
  { "/namespace.experimental.compute.", "{compute_base_url}" },
  { "/namespace.cloud.storage.", "{storage_base_url}" },
  { "/namespace.cloud.github.", "{private_api_base_url}" },
  { "/namespace.private.", "{private_api_base_url}" },
}

return {
  name = "namespacelabs",
  title = "NamespaceLabs",
  base_url = {
    default = "https://global.namespaceapis.com",
    option = "global_base_url",
    env = "NSC_GLOBAL_URL",
  },
  auth = { kind = "bearer", from = "token", env = "NSC_TOKEN" },
  unknown_tag = "UnknownNamespaceLabsError",
  parse_tag = "NamespaceLabsParseError",
  naming = { members = "wire" },
  rpc = {
    wire = "connect",
    options = {
      region = { env = "NSC_REGION", default = "us" },
      compute_base_url = {
        env = { "NSC_COMPUTE_URL", "NSC_ENDPOINT" },
        default = "https://{region}.compute.namespaceapis.com",
      },
      storage_base_url = {
        env = "NSC_STORAGE_URL",
        default = "https://{region}.storage.namespaceapis.com",
      },
      private_api_base_url = {
        env = "NSC_PRIVATE_API_URL",
        default = "https://private-api.global.namespaceapis.com",
      },
    },
    base_url = { by_prefix = by_prefix, default = "{global_base_url}" },
    empty_json_body = true,
    error_envelope = { code = "/code", message = "/message" },
    unknown_fields = { details = "/details" },
  },
}
