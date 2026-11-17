-- Azure's provider spec: one spec for the package's 223 models (one module per resource
-- provider, `require("azure.compute")`, as Distilled's `@distilled.cloud/azure/compute`).
--
-- Mirrors Distilled's hand-written Azure glue (packages/azure/src/):
-- - protocol.ts: lua/distilled/protocol/azure.lua (ARM bearer JSON REST: `Authorization:
--   Bearer <token>`, `Accept: application/json`, `{subscriptionId}` filled from the
--   client's subscription_id when the caller leaves it out, `?api-version=` from each
--   operation's api_version, the ARM error envelope matched by code / message / details,
--   then the status map, unmapped 5xx, UnknownAzureError).
-- - credentials.ts: AZURE_BEARER_TOKEN, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID,
--   AZURE_API_BASE_URL (default https://management.azure.com), resolved on every request.
--   Added (Distilled takes a pre-acquired token only): without a bearer token, Entra ID
--   client credentials (AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID) are
--   exchanged for one at login.microsoftonline.com and reused until 5 minutes before it
--   expires; distilled.azure.credentials has Azure CLI and managed-identity token sources
--   for bearer_token.
-- - errors.ts: lua/distilled/azure/errors.lua (the code map, the message matchers,
--   UnknownAzureError with `target`, AzureParseError).
-- - scripts/generate.ts: member names as the model spells them (the TS surface keeps
--   them: `resourceGroupName`, `_filter` for `$filter`), leading ARM-id labels greedy
--   (gen/azure.lua), no pagination (v0 parity: list operations return `{ value, nextLink }`).
return {
  name = "azure",
  title = "Azure",
  base_url = {
    default = "https://management.azure.com",
    option = "api_base_url",
    env = "AZURE_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "bearer_token", env = "AZURE_BEARER_TOKEN", optional = true },
  options = {
    subscription_id = {
      env = "AZURE_SUBSCRIPTION_ID",
      doc = "fills `{subscriptionId}` when an operation's input leaves it out",
    },
    tenant_id = { env = "AZURE_TENANT_ID", doc = "Azure tenant (directory) ID" },
    -- Microsoft Entra ID client credentials (a service principal), when no bearer_token
    -- is given: not in Distilled, which takes a pre-acquired token only
    client_id = { env = "AZURE_CLIENT_ID", doc = "service principal (app) id, with client_secret" },
    client_secret = {
      secret = true,
      env = "AZURE_CLIENT_SECRET",
      doc = "service principal secret: a token is requested from Entra ID and reused",
    },
    authority_host = {
      env = "AZURE_AUTHORITY_HOST",
      default = "https://login.microsoftonline.com",
      trim_slash = true,
      doc = "the Entra ID host of the cloud",
    },
    scope = {
      default = "https://management.azure.com/.default",
      doc = "the token scope (another cloud: its ARM host + /.default)",
    },
  },
  oauth = {
    token_url = "{authority_host}/{tenant_id}/oauth2/v2.0/token",
    client_id = "client_id",
    client_secret = "client_secret",
    into = "bearer_token",
    auth = "form",
    scope = "scope",
    refresh_window_s = 300,
    required = true,
    label = "Entra ID token request",
  },
  unknown_tag = "UnknownAzureError",
  parse_tag = "AzureParseError",
  naming = { members = "wire" },
  protocol = "distilled.protocol.azure",
}
