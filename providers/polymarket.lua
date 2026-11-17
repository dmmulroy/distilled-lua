-- Polymarket's provider spec: seven APIs, each on its own host.
--
-- Mirrors Distilled's hand-written Polymarket glue (packages/polymarket/src/):
-- - credentials.ts: every part is optional (public reads need none). Three groups, each
--   all or nothing (an incomplete group is a ConfigError naming what is missing, for
--   every API, as CredentialsFromEnv): CLOB L2 (POLY_ADDRESS, CLOB_API_KEY, CLOB_SECRET,
--   CLOB_PASS_PHRASE), relayer (RELAYER_API_KEY_ADDRESS, RELAYER_API_KEY), Perps
--   (POLYMARKET_PROXY, POLYMARKET_SECRET). CLOB_API_URL overrides the CLOB host.
-- - protocol.ts: CLOB and Combos RFQ requests carry the five POLY_* L2 headers, an
--   HMAC-SHA256 of timestamp + METHOD + path + body (signing.ts;
--   glue/polymarket_clob.lua sign); relayer requests RELAYER_API_KEY and
--   RELAYER_API_KEY_ADDRESS; Perps requests POLYMARKET-PROXY and POLYMARKET-SECRET.
--   Failures are { error, code? } (the default envelope); 413 is PayloadTooLarge.
-- - errors.ts: PayloadTooLarge, UnknownPolymarketError, PolymarketParseError.
--
-- Beyond Distilled (which "does not produce" L1): with l1_private_key (POLY_PRIVATE_KEY)
-- set, the CLOB's create_api_key and derive_api_key carry the four L1 headers of
-- Polymarket's clob-client createL1Headers (an EIP-712 ClobAuth signature, secp256k1).
local SECRET_DOC = "sent only to the API it belongs to"
return {
  name = "polymarket",
  title = "Polymarket",
  base_url = { default = "https://gamma-api.polymarket.com", option = "base_url" },
  auth = { kind = "none" },
  options = {
    clob_address = { env = "POLY_ADDRESS", doc = "the signer address that owns the CLOB API key" },
    clob_api_key = { secret = true, env = "CLOB_API_KEY", doc = "CLOB L2 API key" },
    clob_secret = { secret = true, env = "CLOB_SECRET", doc = "CLOB L2 secret (base64)" },
    clob_passphrase = { secret = true, env = "CLOB_PASS_PHRASE", doc = "CLOB L2 passphrase" },
    relayer_address = {
      env = "RELAYER_API_KEY_ADDRESS",
      doc = "the address that owns the relayer key",
    },
    relayer_api_key = { secret = true, env = "RELAYER_API_KEY", doc = SECRET_DOC },
    perps_proxy = { env = "POLYMARKET_PROXY", doc = "the Perps proxy address" },
    perps_secret = { secret = true, env = "POLYMARKET_SECRET", doc = SECRET_DOC },
    l1_private_key = {
      secret = true,
      env = "POLY_PRIVATE_KEY",
      doc = "wallet private key (hex): L1 headers on create_api_key and derive_api_key",
    },
    chain_id = {
      env = "POLY_CHAIN_ID",
      default = "137",
      doc = "EIP-712 chain id of L1 signatures (137 Polygon, 80002 Amoy)",
    },
    l1_nonce = { default = "0", doc = "the nonce of L1 signatures (clob-client's default 0)" },
  },
  glue = "glue/polymarket.lua",
  error_classes = { PayloadTooLarge = { categories = { "BadRequestError" } } },
  status_map = { [413] = "PayloadTooLarge" },
  unknown_tag = "UnknownPolymarketError",
  parse_tag = "PolymarketParseError",
  models = {
    override = {
      clob = {
        base_url = { default = "https://clob.polymarket.com", env = "CLOB_API_URL" },
        glue = "glue/polymarket_clob.lua",
      },
      combos_rfq = {
        base_url = { default = "https://combos-rfq-api.polymarket.com" },
        glue = "glue/polymarket_clob.lua",
      },
      data = { base_url = { default = "https://data-api.polymarket.com" } },
      relayer = {
        base_url = { default = "https://relayer-v2.polymarket.com" },
        headers = {
          relayer_api_key = "{relayer_api_key}",
          relayer_api_key_address = "{relayer_address}",
        },
      },
      bridge = { base_url = { default = "https://bridge.polymarket.com" } },
      perps = {
        base_url = { default = "https://api.perpetuals.polymarket.com" },
        headers = {
          ["polymarket-proxy"] = "{perps_proxy}",
          ["polymarket-secret"] = "{perps_secret}",
        },
      },
    },
  },
}
