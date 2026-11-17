-- Vercel's provider spec.
--
-- Mirrors Distilled's hand-written Vercel glue (packages/vercel/src/):
-- - credentials.ts: the token from VERCEL_TOKEN; the base URL from VERCEL_API_URL,
--   default https://api.vercel.com.
-- - protocol.ts: bearer auth; failures are { error = { code, message } }; 402 is
--   PaymentRequired and 410 (an unsupported API version) Gone.
-- - errors.ts: PaymentRequired (quota), Gone (not found), UnknownVercelError,
--   VercelParseError.
return {
  name = "vercel",
  title = "Vercel",
  base_url = { default = "https://api.vercel.com", option = "base_url", env = "VERCEL_API_URL" },
  auth = { kind = "bearer", from = "token", env = "VERCEL_TOKEN" },
  error_envelope = { code = "/error/code", message = "/error/message" },
  error_classes = {
    PaymentRequired = { categories = { "QuotaError" } },
    Gone = { categories = { "NotFoundError" } },
  },
  status_map = { [402] = "PaymentRequired", [410] = "Gone" },
  unknown_tag = "UnknownVercelError",
  parse_tag = "VercelParseError",
}
