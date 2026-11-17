-- Stripe's provider spec.
--
-- Mirrors Distilled's hand-written Stripe glue (packages/stripe/src/):
-- - credentials.ts: the key from STRIPE_API_KEY; base URL https://api.stripe.com (an
--   option only).
-- - protocol.ts: bearer auth, Stripe-Version (api-version.ts API_VERSION
--   2026-10-28.endive; Distilled's ApiVersion service is the api_version option here),
--   Accept JSON, Stripe-Context when a context is set; nested query values in bracket
--   style; failures are { error = { type, code, message, param, ... } } read by
--   error.type (matchStripeError, glue/stripe.lua): card_error, idempotency_error,
--   invalid_request_error and api_error have classes of their own, then 402
--   PaymentError and 424 ExternalDependencyFailed; the unknown error carries type and
--   param.
-- - errors.ts: CardError, IdempotencyError, InvalidRequestError, ApiError,
--   PaymentError, ExternalDependencyFailed, UnknownStripeError, StripeParseError.
--
-- Not mirrored: an error.type outside those four on a status the Stripe map lacks is
-- matched against the operation's declared errors before the shared status map.
return {
  name = "stripe",
  title = "Stripe",
  base_url = { default = "https://api.stripe.com", option = "base_url" },
  auth = { kind = "bearer", from = "api_key", env = "STRIPE_API_KEY" },
  options = {
    api_version = { default = "2026-10-28.endive", doc = "Stripe-Version" },
    context = { doc = "Stripe-Context (act for a connected account)" },
  },
  headers = { ["Stripe-Version"] = "{api_version}", ["Stripe-Context"] = "{context}" },
  query_style = "brackets",
  error_envelope = { code = "/error/code", message = "/error/message" },
  unknown_fields = { type = "/error/type", param = "/error/param" },
  glue = "glue/stripe.lua",
  unknown_tag = "UnknownStripeError",
  parse_tag = "StripeParseError",
}
