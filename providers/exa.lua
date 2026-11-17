-- Exa's provider spec (models api and team_management).
--
-- Mirrors Distilled's hand-written Exa glue (packages/exa/src/):
-- - credentials.ts (model api): the key from EXA_API_KEY; the base URL from
--   EXA_API_BASE_URL, default https://api.exa.ai.
-- - protocol.ts: an x-api-key header; failures are { tag, error | message }.
-- - errors.ts: UnknownExaError, ExaParseError.
--
-- The team_management model needs task 10's per-model override, once it covers auth
-- and options: x-api-key from service_api_key (EXA_SERVICE_API_KEY) or api_key, base URL
-- https://admin-api.exa.ai/team-management (no environment variable).
return {
  name = "exa",
  title = "Exa",
  base_url = { default = "https://api.exa.ai", option = "base_url", env = "EXA_API_BASE_URL" },
  auth = { kind = "header", header = "x-api-key", from = "api_key", env = "EXA_API_KEY" },
  -- ListWebsets' item iterator (list_websets_items) would collide with ListWebsetsItems
  naming = { operations = { ListWebsetsItems = "list_webset_items" } },
  error_envelope = { code = "/tag", message = { "/error", "/message" } },
  unknown_tag = "UnknownExaError",
  parse_tag = "ExaParseError",
}
