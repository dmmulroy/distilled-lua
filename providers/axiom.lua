-- Axiom's provider spec.
--
-- Mirrors Distilled's hand-written Axiom glue (packages/axiom/src/):
-- - credentials.ts: the token from AXIOM_TOKEN, else AXIOM_API_KEY; the base URL from
--   AXIOM_URL, default https://api.axiom.co; the organization from AXIOM_ORG_ID.
-- - protocol.ts: bearer auth; X-Axiom-Org-ID when an organization is set; failures are
--   { code | error, message | error }; transformResponse strips null members.
-- - errors.ts: UnknownAxiomError, AxiomParseError.
return {
  name = "axiom",
  title = "Axiom",
  base_url = { default = "https://api.axiom.co", option = "base_url", env = "AXIOM_URL" },
  auth = { kind = "bearer", from = "api_key", env = { "AXIOM_TOKEN", "AXIOM_API_KEY" } },
  options = { org_id = { env = "AXIOM_ORG_ID", doc = "organization (X-Axiom-Org-ID)" } },
  headers = { ["X-Axiom-Org-ID"] = "{org_id}" },
  error_envelope = { code = { "/code", "/error" }, message = { "/message", "/error" } },
  transform_response = { "strip_nulls" },
  unknown_tag = "UnknownAxiomError",
  parse_tag = "AxiomParseError",
}
