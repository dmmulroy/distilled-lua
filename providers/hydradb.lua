-- HydraDB's provider spec.
--
-- Mirrors Distilled's hand-written HydraDB glue (packages/hydradb/src/):
-- - credentials.ts: the key from HYDRADB_API_KEY; the base URL from HYDRADB_API_URL,
--   default https://api.hydradb.com, trailing slashes removed.
-- - protocol.ts: bearer auth, API-Version: 2; failures are { error = { code, message } }
--   or { detail = { error_code, message } } or { message | error } (non-empty text);
--   a { success, data [, error, meta] } answer is unwrapped to data (glue/hydradb.lua).
-- - errors.ts: UnknownHydraDBError, HydraDBParseError.
return {
  name = "hydradb",
  title = "HydraDB",
  base_url = {
    default = "https://api.hydradb.com",
    option = "base_url",
    env = "HYDRADB_API_URL",
    trim_slash = true,
  },
  auth = { kind = "bearer", from = "api_key", env = "HYDRADB_API_KEY" },
  headers = { ["API-Version"] = "2" },
  error_envelope = {
    code = { "/error/code", "/detail/error_code" },
    message = { "/error/message", "/detail/message", "/message", "/error" },
    non_empty = true,
  },
  glue = "glue/hydradb.lua",
  unknown_tag = "UnknownHydraDBError",
  parse_tag = "HydraDBParseError",
}
