-- Namespace's provider spec (package namespacelabs).
--
-- Mirrors Distilled's hand-written Namespace glue (packages/namespacelabs/src/):
-- - credentials.ts: the token from NSC_TOKEN; the region from NSC_REGION, default us;
--   compute from NSC_COMPUTE_URL, else NSC_ENDPOINT, default
--   https://{region}.compute.namespaceapis.com; storage from NSC_STORAGE_URL, default
--   https://{region}.storage.namespaceapis.com; global from NSC_GLOBAL_URL, default
--   https://global.namespaceapis.com; private API from NSC_PRIVATE_API_URL, default
--   https://private-api.global.namespaceapis.com.
-- - protocol.ts: bearer auth; the host by the route's service package prefix
--   (HOST_BY_PACKAGE_PREFIX, glue/namespacelabs.lua); bodied calls send {} without
--   members (emptyJsonBody); failures are { code, message }; the unknown error
--   carries `details`.
-- - errors.ts: UnknownNamespaceLabsError, NamespaceLabsParseError.
--
-- Not mirrored: CredentialsFromTokenFile (NSC_TOKEN_FILE, a JSON file with
-- bearer_token): read the file and pass token = ... .
return {
  name = "namespacelabs",
  title = "NamespaceLabs",
  base_url = {
    default = "https://global.namespaceapis.com",
    option = "global_base_url",
    env = "NSC_GLOBAL_URL",
  },
  auth = { kind = "bearer", from = "token", env = "NSC_TOKEN" },
  options = {
    region = { env = "NSC_REGION", default = "us" },
    compute_base_url = { env = { "NSC_COMPUTE_URL", "NSC_ENDPOINT" } },
    storage_base_url = { env = "NSC_STORAGE_URL" },
    private_api_base_url = {
      env = "NSC_PRIVATE_API_URL",
      default = "https://private-api.global.namespaceapis.com",
    },
  },
  empty_json_body = true,
  error_envelope = { code = "/code", message = "/message" },
  unknown_fields = { details = "/details" },
  glue = "glue/namespacelabs.lua",
  unknown_tag = "UnknownNamespaceLabsError",
  parse_tag = "NamespaceLabsParseError",
}
