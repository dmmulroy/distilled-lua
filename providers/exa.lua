-- Exa's provider spec (models api and team_management).
--
-- Mirrors Distilled's hand-written Exa glue (packages/exa/src/):
-- - credentials.ts (model api): the key from EXA_API_KEY; the base URL from
--   EXA_API_BASE_URL, default https://api.exa.ai.
-- - protocol.ts: an x-api-key header; failures are { tag, error | message }.
-- - errors.ts: UnknownExaError, ExaParseError.
--
-- - protocol.ts ExaTeamManagementProtocol (model team_management): x-api-key is
--   service_api_key (EXA_SERVICE_API_KEY) when set, else api_key (EXA_API_KEY); the base
--   URL is teamManagementBaseUrl, default https://admin-api.exa.ai/team-management (no
--   environment variable).
return {
  name = "exa",
  title = "Exa",
  base_url = { default = "https://api.exa.ai", option = "base_url", env = "EXA_API_BASE_URL" },
  auth = { kind = "header", header = "x-api-key", from = "api_key", env = "EXA_API_KEY" },
  -- ListWebsets' item iterator (list_websets_items) would collide with ListWebsetsItems
  naming = { operations = { ListWebsetsItems = "list_webset_items" } },
  error_envelope = { code = "/tag", message = { "/error", "/message" } },
  models = {
    override = {
      team_management = {
        base_url = { default = "https://admin-api.exa.ai/team-management", env = false },
        auth = false,
        options = {
          api_key = { secret = true, env = "EXA_API_KEY" },
          service_api_key = { secret = true, env = "EXA_SERVICE_API_KEY" },
        },
        require_one_of = { "service_api_key", "api_key" },
        headers = { ["x-api-key"] = { "{service_api_key}", "{api_key}" } },
      },
    },
  },
  unknown_tag = "UnknownExaError",
  parse_tag = "ExaParseError",
}
