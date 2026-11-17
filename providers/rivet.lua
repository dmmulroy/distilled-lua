-- Rivet's provider spec.
--
-- Mirrors Distilled's hand-written Rivet glue (packages/rivet/src/):
-- - credentials.ts: the token from RIVET_TOKEN, else the (URL-decoded) password of
--   RIVET_ENDPOINT's userinfo, which is removed from the endpoint; the endpoint from
--   RIVET_ENDPOINT, default https://api.rivet.dev, trailing slashes removed
--   (glue/rivet.lua).
-- - protocol.ts: bearer auth; failures are { group, code, message }, code "group.code".
-- - errors.ts: UnknownRivetError, RivetParseError.
return {
  name = "rivet",
  title = "Rivet",
  base_url = { default = "https://api.rivet.dev", option = "endpoint", env = "RIVET_ENDPOINT" },
  -- required in glue/rivet.lua: the endpoint's userinfo may carry it
  auth = { kind = "bearer", from = "token", env = "RIVET_TOKEN", optional = true },
  glue = "glue/rivet.lua",
  unknown_tag = "UnknownRivetError",
  parse_tag = "RivetParseError",
}
