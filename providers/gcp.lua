-- GCP's provider spec: one spec for the package's 315 stable and 214 unstable models (one
-- module per Google service, `require("gcp.storage_v1")`, and
-- `require("gcp.unstable.compute_beta")` for the non-preferred versions, as Distilled's
-- `@distilled.cloud/gcp/storage_v1` and `@distilled.cloud/gcp/unstable/compute_beta`).
--
-- Mirrors Distilled's hand-written GCP glue (packages/gcp/src/ and scripts/generate.ts):
-- - protocol.ts, endpoint.ts, region.ts, regional-endpoints.ts, errors.ts: the
--   hand-written protocol lua/distilled/gcp/protocol.lua (bearer token and
--   X-Goog-User-Project per request, `{+name}` reserved expansion, the
--   `{ error: { code, message, status, details } }` envelope, UnknownGCPError,
--   GCPParseError, the endpoint override and regional endpoints).
-- - credentials*.ts, credential-providers/: lua/distilled/gcp/credentials.lua (access
--   token, Application Default Credentials, authorized user, metadata server, service
--   account key, workload identity), tokens cached and refreshed 5 minutes early.
-- - generate.ts: the discovery passes (per-service base URL from the model metadata,
--   flattened request bodies, the com.gcp.protocols#errorMatchers trait, the envelope's
--   `details` on every error class, operation names without a trailing _) are
--   gen/discovery.lua; the token pagination profile (pageToken -> nextPageToken, items
--   absent on most list responses) is `pagination.items_fallback = ""`.
-- - Wire names are the surface (Distilled keeps them: GCP wire names are camelCase).
return {
  name = "gcp",
  title = "GCP",
  auth = { kind = "none" },
  unknown_tag = "UnknownGCPError",
  parse_tag = "GCPParseError",
  protocol = "distilled.gcp.protocol",
  discovery = { error_matchers = "com.gcp.protocols#errorMatchers" },
  options = {
    access_token = {
      secret = true,
      doc = "An OAuth2 access token (`gcloud auth print-access-token`). When neither this "
        .. "nor `credentials` is set: GOOGLE_ACCESS_TOKEN, then Application Default "
        .. "Credentials (distilled.gcp.credentials).",
    },
    credentials = {
      type = "table",
      doc = "A credentials provider from `distilled.gcp.credentials` "
        .. "(from_application_default, from_authorized_user, from_service_account_key, "
        .. "from_metadata_server, from_workload_identity, from_access_token); tokens are "
        .. "cached and refreshed five minutes before they expire.",
    },
    quota_project = {
      type = "string",
      doc = "The project billed for quota (`X-Goog-User-Project`); wins over the "
        .. "credentials' own (GOOGLE_CLOUD_QUOTA_PROJECT, quota_project_id).",
    },
    endpoint = {
      type = "string",
      doc = "Replaces the scheme and host of every request, keeping the service path "
        .. "(emulators, private hosts). Default: GOOGLE_API_ENDPOINT.",
    },
    regional_endpoints = {
      type = "string",
      doc = '"required" (default: regional hosts only where the global host refuses '
        .. 'regional resources: Vertex AI, Secret Manager, Parameter Manager), "prefer" '
        .. '(the location\'s regional host whenever Google publishes one) or "never".',
    },
  },
  naming = { members = "wire" },
  pagination = { items_fallback = "" },
}
