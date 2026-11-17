-- Coinbase CDP's provider spec.
--
-- Mirrors Distilled's hand-written Coinbase glue (packages/coinbase/src/):
-- - credentials.ts: CDP_API_KEY_ID (or CDP_API_KEY_NAME) and CDP_API_KEY_SECRET;
--   CDP_WALLET_SECRET is read but, as in Distilled, no X-Wallet-Auth header is made.
--   The base URL is https://api.cdp.coinbase.com/platform.
-- - protocol.ts: every request carries `Authorization: Bearer <JWT>`, a fresh JWT per
--   request signed with the API key secret: ES256 for an EC PEM key, EdDSA for the
--   base64 Ed25519 seed || public key (glue/coinbase.lua sign). Failures are
--   { errorType, errorMessage, correlationId, errorLink }, dispatched by errorType,
--   then by status (glue/coinbase.lua classify_error); failure bodies carrying isValid
--   or success are success values (accept_failure).
-- - errors.ts: the 49 errorType classes, UnknownCoinbaseError, CoinbaseParseError.
return {
  name = "coinbase",
  title = "Coinbase",
  base_url = {
    default = "https://api.cdp.coinbase.com/platform",
    option = "base_url",
    trim_slash = true,
  },
  auth = { kind = "none" },
  options = {
    api_key_id = {
      env = { "CDP_API_KEY_ID", "CDP_API_KEY_NAME" },
      doc = "the CDP API key id (a UUID, or organizations/.../apiKeys/...)",
    },
    api_key_secret = {
      secret = true,
      env = "CDP_API_KEY_SECRET",
      doc = "the CDP API key secret: an EC PEM private key (ES256) or the base64 Ed25519 key (EdDSA)",
    },
    wallet_secret = {
      secret = true,
      env = "CDP_WALLET_SECRET",
      doc = "the CDP wallet secret (read, not used: no X-Wallet-Auth header is made, as in Distilled)",
    },
  },
  glue = "glue/coinbase.lua",
  unknown_tag = "UnknownCoinbaseError",
  parse_tag = "CoinbaseParseError",
}
