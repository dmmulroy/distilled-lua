-- Google Workspace's provider spec: one spec for the package's 28 stable and 7 unstable
-- models (`require("google_workspace.gmail_v1")`,
-- `require("google_workspace.unstable.drive_v2")`, as Distilled's
-- `@distilled.cloud/google-workspace/gmail_v1` and `.../unstable/drive_v2`).
--
-- Mirrors Distilled's hand-written glue (packages/google-workspace/src/):
-- - protocol.ts, errors.ts: lua/distilled/gcp/workspace.lua, the GCP protocol without
--   the quota project header, the endpoint override and regional endpoints; the
--   `{ error: { code, message, status, details } }` envelope, UnknownGoogleWorkspaceError,
--   GoogleWorkspaceParseError.
-- - credentials.ts: an externally minted OAuth2 access token (`access_token`, else
--   GOOGLE_ACCESS_TOKEN). Beyond Distilled, `credentials` takes any provider of
--   distilled.gcp.credentials (a refreshing user or service-account login).
-- - scripts/generate.ts: the same discovery passes as gcp (gen/discovery.lua), with the
--   com.googleworkspace.protocols#errorMatchers trait.
return {
  name = "google_workspace",
  title = "GoogleWorkspace",
  auth = { kind = "none" },
  unknown_tag = "UnknownGoogleWorkspaceError",
  parse_tag = "GoogleWorkspaceParseError",
  protocol = "distilled.gcp.workspace",
  discovery = { error_matchers = "com.googleworkspace.protocols#errorMatchers" },
  options = {
    access_token = {
      secret = true,
      doc = "An OAuth2 access token (`gcloud auth print-access-token`). Default: "
        .. "GOOGLE_ACCESS_TOKEN.",
    },
    credentials = {
      type = "table",
      doc = "A credentials provider from `distilled.gcp.credentials` (from_authorized_user, "
        .. "from_service_account_key, from_application_default, ...); wins over "
        .. "access_token.",
    },
  },
  naming = { members = "wire" },
  pagination = { items_fallback = "" },
}
