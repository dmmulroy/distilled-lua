-- STACKIT's provider spec (52 models).
--
-- Mirrors Distilled's hand-written STACKIT glue (packages/stackit/src/):
-- - credentials.ts: the service-account token from STACKIT_SERVICE_ACCOUNT_TOKEN; the
--   region from STACKIT_REGION, default eu01; STACKIT_API_BASE_URL overrides every
--   operation's base URL.
-- - protocol.ts: bearer auth; each operation's base URL is its http trait's baseUrl
--   with the region applied (applyRegion, glue/stackit.lua); failures are
--   { error | code, message }, matched on numeric codes only.
-- - errors.ts: UnknownStackitError, StackitParseError.
--
-- The per-operation base URL is task 12's route.base_url (the http trait's baseUrl).
return {
  name = "stackit",
  title = "Stackit",
  base_url = { option = "base_url", env = "STACKIT_API_BASE_URL" },
  auth = { kind = "bearer", from = "token", env = "STACKIT_SERVICE_ACCOUNT_TOKEN" },
  options = { region = { env = "STACKIT_REGION", default = "eu01" } },
  error_envelope = { code = { "/error", "/code" }, message = "/message" },
  glue = "glue/stackit.lua",
  unknown_tag = "UnknownStackitError",
  parse_tag = "StackitParseError",
}
