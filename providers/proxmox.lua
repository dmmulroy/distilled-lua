-- Proxmox VE's provider spec.
--
-- Mirrors Distilled's hand-written Proxmox glue (packages/proxmox/src/):
-- - credentials.ts: the token id from PROXMOX_TOKEN_ID and secret from
--   PROXMOX_TOKEN_SECRET; the endpoint from PROXMOX_ENDPOINT (required): an HTTPS URL
--   without credentials, query or fragment, whose path is empty or /api2/json, and
--   becomes /api2/json (apiRoot, glue/proxmox.lua).
-- - protocol.ts: Authorization "PVEAPIToken=<id>=<secret>", Accept JSON; top-level
--   boolean inputs are sent as 1/0; a { data } answer is unwrapped; failures are
--   { message, errors = { name = reason } } joined by newlines.
-- - errors.ts: UnknownProxmoxError, ProxmoxParseError.
return {
  name = "proxmox",
  title = "Proxmox",
  base_url = { option = "endpoint", env = "PROXMOX_ENDPOINT" },
  options = {
    token_id = { secret = true, env = "PROXMOX_TOKEN_ID", required = true },
    token_secret = { secret = true, env = "PROXMOX_TOKEN_SECRET", required = true },
  },
  headers = { Authorization = "PVEAPIToken={token_id}={token_secret}" },
  transform_response = { { unwrap = "data" } },
  glue = "glue/proxmox.lua",
  unknown_tag = "UnknownProxmoxError",
  parse_tag = "ProxmoxParseError",
}
