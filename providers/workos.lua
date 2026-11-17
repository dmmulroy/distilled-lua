-- WorkOS's provider spec.
--
-- Mirrors Distilled's hand-written WorkOS glue (packages/workos/src/):
-- - credentials.ts: the key from WORKOS_API_KEY; the base URL from WORKOS_API_URL,
--   default https://api.workos.com.
-- - protocol.ts: bearer auth; failures are { code, message | error_description | error }.
-- - errors.ts: UnknownWorkosError, WorkosParseError.
return {
  name = "workos",
  title = "Workos",
  base_url = { default = "https://api.workos.com", option = "base_url", env = "WORKOS_API_URL" },
  auth = { kind = "bearer", from = "api_key", env = "WORKOS_API_KEY" },
  error_envelope = { code = "/code", message = { "/message", "/error_description", "/error" } },
  unknown_tag = "UnknownWorkosError",
  parse_tag = "WorkosParseError",
}
