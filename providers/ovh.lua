-- OVHcloud's provider spec.
--
-- Mirrors Distilled's hand-written OVH glue (packages/ovh/src/):
-- - credentials.ts: the token from OVH_ACCESS_TOKEN; the base URL from OVH_API_BASE_URL,
--   else the OVH_ENDPOINT region (ENDPOINTS; an unknown one is the default), default
--   https://eu.api.ovh.com/1.0.
-- - protocol.ts: bearer auth; failures are { errorCode | class | code, message }.
-- - errors.ts: UnknownOvhError, OvhParseError.
return {
  name = "ovh",
  title = "Ovh",
  base_url = { default = "{endpoint}", option = "base_url", env = "OVH_API_BASE_URL" },
  auth = { kind = "bearer", from = "api_key", env = "OVH_ACCESS_TOKEN" },
  options = {
    endpoint = {
      env = "OVH_ENDPOINT",
      default = "ovh-eu",
      choices = {
        ["ovh-eu"] = "https://eu.api.ovh.com/1.0",
        ["ovh-us"] = "https://api.us.ovhcloud.com/1.0",
        ["ovh-ca"] = "https://ca.api.ovh.com/1.0",
      },
      invalid = "default",
    },
  },
  error_envelope = { code = { "/errorCode", "/class", "/code" }, message = "/message" },
  unknown_tag = "UnknownOvhError",
  parse_tag = "OvhParseError",
}
