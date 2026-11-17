-- Dokploy's provider spec.
--
-- Mirrors Distilled's hand-written Dokploy glue (packages/dokploy/src/):
-- - credentials.ts: the key from DOKPLOY_API_KEY; the server URL from DOKPLOY_URL
--   (required, trailing slashes removed), base URL {url}/api.
-- - protocol.ts: an x-api-key header.
-- - errors.ts: UnknownDokployError, DokployParseError.
return {
  name = "dokploy",
  title = "Dokploy",
  base_url = { default = "{url}/api", option = "base_url" },
  auth = { kind = "header", header = "x-api-key", from = "api_key", env = "DOKPLOY_API_KEY" },
  options = {
    url = { env = "DOKPLOY_URL", trim_slash = true, doc = "Dokploy server URL" },
  },
  unknown_tag = "UnknownDokployError",
  parse_tag = "DokployParseError",
}
