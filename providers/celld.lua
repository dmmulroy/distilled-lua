-- Celld's provider spec.
--
-- Mirrors Distilled's hand-written Celld glue (packages/celld/src/):
-- - endpoint.ts: no credentials; the endpoint URL is required and has no default or
--   environment variable.
-- - protocol.ts: failures are { ok = false, error = { kind, reason } } (message
--   "kind: reason") or the default { code, message | error } (glue/celld.lua).
-- - errors.ts: UnknownCelldError, CelldParseError.
return {
  name = "celld",
  title = "Celld",
  base_url = { option = "base_url" },
  auth = { kind = "none" },
  glue = "glue/celld.lua",
  unknown_tag = "UnknownCelldError",
  parse_tag = "CelldParseError",
}
