-- ZeroSSL's provider spec.
--
-- Mirrors Distilled's hand-written ZeroSSL glue (packages/zerossl/src/):
-- - credentials.ts: the key from ZEROSSL_ACCESS_KEY, else ZERO_SSL_KEY; base URL
--   https://api.zerossl.com.
-- - protocol.ts (its own decode): Authorization "ApiKey <key>", Accept JSON; a 2xx
--   answer with success false or 0 is a failure too; the message is error.info |
--   error.type, the code error.code (a number); success 1/0 is decoded as a boolean
--   (glue/zerossl.lua).
-- - errors.ts: UnknownZeroSslError, ZeroSslParseError.
--
-- Not mirrored: the unknown error's `type` field and its redacted body.
return {
  name = "zerossl",
  title = "ZeroSsl",
  base_url = { default = "https://api.zerossl.com", option = "base_url" },
  auth = {
    kind = "header",
    header = "Authorization",
    prefix = "ApiKey ",
    from = "access_key",
    env = { "ZEROSSL_ACCESS_KEY", "ZERO_SSL_KEY" },
  },
  error_envelope = { code = "/error/code", message = { "/error/info", "/error/type" } },
  glue = "glue/zerossl.lua",
  unknown_tag = "UnknownZeroSslError",
  parse_tag = "ZeroSslParseError",
}
