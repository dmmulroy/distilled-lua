-- Steel's provider spec.
--
-- Mirrors Distilled's hand-written Steel glue (packages/steel/src/):
-- - credentials.ts: the key from STEEL_API_KEY; the base URL from STEEL_BASE_URL, default
--   https://api.steel.dev, trailing slashes removed.
-- - protocol.ts: a steel-api-key header; failures are { error = { code, message } },
--   { error = text } or { code, message }.
-- - errors.ts: UnknownSteelError, SteelParseError.
--
-- Differs from Distilled: when `error` is an object without a code, Distilled reports no
-- code; the pointer list falls back to a top-level `code`.
return {
  name = "steel",
  title = "Steel",
  base_url = {
    default = "https://api.steel.dev",
    option = "base_url",
    env = "STEEL_BASE_URL",
    trim_slash = true,
  },
  auth = { kind = "header", header = "steel-api-key", from = "api_key", env = "STEEL_API_KEY" },
  error_envelope = {
    code = { "/error/code", "/code" },
    message = { "/error/message", "/message", "/error" },
  },
  unknown_tag = "UnknownSteelError",
  parse_tag = "SteelParseError",
}
