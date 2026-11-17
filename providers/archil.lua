-- Archil's provider spec.
--
-- Mirrors Distilled's hand-written Archil glue (packages/archil/src/):
-- - credentials.ts: the key from ARCHIL_API_KEY; the control plane from the region
--   (ARCHIL_REGION, default aws-us-east-1, REGIONS below; an unknown region is a
--   ConfigError), unless ARCHIL_API_BASE_URL gives the base URL.
-- - protocol.ts: the raw key in Authorization; the unknown error's message falls back to
--   a string `error` member (as the default envelope does).
-- - errors.ts: UnknownArchilError, ArchilParseError.
return {
  name = "archil",
  title = "Archil",
  base_url = { default = "{region}", option = "base_url", env = "ARCHIL_API_BASE_URL" },
  auth = { kind = "header", header = "Authorization", from = "api_key", env = "ARCHIL_API_KEY" },
  options = {
    region = {
      env = "ARCHIL_REGION",
      default = "aws-us-east-1",
      choices = {
        ["aws-us-east-1"] = "https://control.green.us-east-1.aws.prod.archil.com",
        ["aws-us-west-2"] = "https://control.green.us-west-2.aws.prod.archil.com",
        ["aws-eu-west-1"] = "https://control.green.eu-west-1.aws.prod.archil.com",
        ["gcp-us-central1"] = "https://control.blue.us-central1.gcp.prod.archil.com",
      },
      doc = "control-plane region",
    },
  },
  unknown_tag = "UnknownArchilError",
  parse_tag = "ArchilParseError",
}
