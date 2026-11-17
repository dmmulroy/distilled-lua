-- Grafana's provider spec.
--
-- Mirrors Distilled's hand-written Grafana glue (packages/grafana/src/):
-- - credentials.ts: the token from GRAFANA_TOKEN; the URL from GRAFANA_URL, default
--   http://localhost:3000; the organization from GRAFANA_ORG_ID.
-- - protocol.ts: bearer auth, Accept JSON, X-Grafana-Org-Id when set; the base URL is
--   trimmed of trailing slashes and gets /api unless it ends with it.
-- - errors.ts: UnknownGrafanaError, GrafanaParseError.
return {
  name = "grafana",
  title = "Grafana",
  base_url = {
    default = "http://localhost:3000",
    option = "base_url",
    env = "GRAFANA_URL",
    ensure_suffix = "/api",
  },
  auth = { kind = "bearer", from = "token", env = "GRAFANA_TOKEN" },
  options = { org_id = { env = "GRAFANA_ORG_ID", doc = "organization (X-Grafana-Org-Id)" } },
  headers = { ["X-Grafana-Org-Id"] = "{org_id}" },
  unknown_tag = "UnknownGrafanaError",
  parse_tag = "GrafanaParseError",
}
