-- Unkey's provider spec.
--
-- Mirrors Distilled's hand-written Unkey glue (packages/unkey/src/):
-- - credentials.ts: the root key from UNKEY_ROOT_KEY; the base URL from
--   UNKEY_API_BASE_URL, default https://api.unkey.com.
-- - protocol.ts: bearer auth; failures are problem documents, under `error` or at the
--   top: { type | code, detail | title | message }.
-- - errors.ts: UnknownUnkeyError, UnkeyParseError.
--
-- Differs from Distilled: when `error` is an object, Distilled reads only its members;
-- the pointer lists fall back to top-level ones.
return {
  name = "unkey",
  title = "Unkey",
  base_url = { default = "https://api.unkey.com", option = "base_url", env = "UNKEY_API_BASE_URL" },
  auth = { kind = "bearer", from = "api_key", env = "UNKEY_ROOT_KEY" },
  error_envelope = {
    code = { "/error/type", "/error/code", "/type", "/code" },
    message = {
      "/error/detail",
      "/error/title",
      "/error/message",
      "/detail",
      "/title",
      "/message",
    },
  },
  unknown_tag = "UnknownUnkeyError",
  parse_tag = "UnkeyParseError",
}
