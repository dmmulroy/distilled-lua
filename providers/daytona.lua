-- Daytona's provider spec.
--
-- Mirrors Distilled's hand-written Daytona glue (packages/daytona/src/):
-- - credentials.ts: the key from DAYTONA_API_KEY; the API from DAYTONA_API_URL, default
--   https://app.daytona.io/api; analytics from DAYTONA_ANALYTICS_URL, default
--   https://analytics.app.daytona.io; the toolbox from DAYTONA_TOOLBOX_URL, default
--   https://proxy.app.daytona.io/toolbox/{sandboxId}; the sandbox from
--   DAYTONA_SANDBOX_ID; the organization from DAYTONA_ORGANIZATION_ID.
-- - protocol.ts: bearer auth, X-Daytona-SDK-Version 0.229.2, X-Daytona-Source
--   distilled, X-Daytona-Organization-ID when set; /organization routes go to
--   analytics, toolbox roots (endpoints.ts TOOLBOX_ROOTS) to the sandbox's toolbox,
--   the rest to the API (glue/daytona.lua); null members are stripped from answers.
-- - errors.ts: UnknownDaytonaError, DaytonaParseError.
return {
  name = "daytona",
  title = "Daytona",
  base_url = {
    default = "https://app.daytona.io/api",
    option = "base_url",
    env = "DAYTONA_API_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "DAYTONA_API_KEY" },
  options = {
    analytics_base_url = {
      env = "DAYTONA_ANALYTICS_URL",
      default = "https://analytics.app.daytona.io",
    },
    toolbox_base_url = {
      env = "DAYTONA_TOOLBOX_URL",
      default = "https://proxy.app.daytona.io/toolbox/{sandboxId}",
    },
    sandbox_id = { env = "DAYTONA_SANDBOX_ID", doc = "the sandbox of toolbox calls" },
    organization_id = { env = "DAYTONA_ORGANIZATION_ID" },
  },
  headers = {
    ["X-Daytona-SDK-Version"] = "0.229.2",
    ["X-Daytona-Source"] = "distilled",
    ["X-Daytona-Organization-ID"] = "{organization_id}",
  },
  transform_response = { "strip_nulls" },
  glue = "glue/daytona.lua",
  unknown_tag = "UnknownDaytonaError",
  parse_tag = "DaytonaParseError",
}
