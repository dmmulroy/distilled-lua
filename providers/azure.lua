-- Azure's provider spec: one spec for the package's 223 models (one module per resource
-- provider, `require("azure.compute")`, as Distilled's `@distilled.cloud/azure/compute`).
--
-- Mirrors Distilled's hand-written Azure glue (packages/azure/src/):
-- - protocol.ts: lua/distilled/protocol/azure.lua (ARM bearer JSON REST: `Authorization:
--   Bearer <token>`, `Accept: application/json`, `{subscriptionId}` filled from the
--   client's subscription_id when the caller leaves it out, `?api-version=` from each
--   operation's api_version, the ARM error envelope matched by code / message / details,
--   then the status map, unmapped 5xx, UnknownAzureError).
-- - credentials.ts: AZURE_BEARER_TOKEN (required), AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID,
--   AZURE_API_BASE_URL (default https://management.azure.com).
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
  auth = { kind = "bearer", from = "bearer_token", env = "AZURE_BEARER_TOKEN" },
  options = {
    subscription_id = {
      env = "AZURE_SUBSCRIPTION_ID",
      doc = "fills `{subscriptionId}` when an operation's input leaves it out",
    },
    tenant_id = { env = "AZURE_TENANT_ID", doc = "Azure tenant (directory) ID" },
  },
  unknown_tag = "UnknownAzureError",
  parse_tag = "AzureParseError",
  naming = { members = "wire" },
  protocol = "distilled.protocol.azure",
}
