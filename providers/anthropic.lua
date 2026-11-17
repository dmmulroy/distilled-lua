-- Anthropic's provider spec.
--
-- Mirrors Distilled's hand-written Anthropic glue (packages/anthropic/src/):
-- - credentials.ts: the key from ANTHROPIC_API_KEY; the base URL from ANTHROPIC_BASE_URL,
--   default https://api.anthropic.com; the API version from ANTHROPIC_VERSION, default
--   2026-10-21 (DEFAULT_ANTHROPIC_VERSION).
-- - protocol.ts: x-api-key and anthropic-version headers; failures are
--   { error = { type, message } }; 529 (overloaded) is ServiceUnavailable.
-- - errors.ts: UnknownAnthropicError, AnthropicParseError.
return {
  name = "anthropic",
  title = "Anthropic",
  base_url = {
    default = "https://api.anthropic.com",
    option = "base_url",
    env = "ANTHROPIC_BASE_URL",
  },
  auth = { kind = "header", header = "x-api-key", from = "api_key", env = "ANTHROPIC_API_KEY" },
  options = {
    version = {
      env = "ANTHROPIC_VERSION",
      default = "2026-10-21",
      doc = "anthropic-version header",
    },
  },
  headers = { ["anthropic-version"] = "{version}" },
  error_envelope = { code = "/error/type", message = "/error/message" },
  status_map = { [529] = "ServiceUnavailable" },
  unknown_tag = "UnknownAnthropicError",
  parse_tag = "AnthropicParseError",
}
