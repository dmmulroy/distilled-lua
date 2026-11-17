-- Argocd's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Argocd glue (packages/argocd/src/):
-- - credentials.ts: the key from ARGOCD_TOKEN; the base URL from ARGOCD_SERVER,
--   default https://localhost:8080.
-- - protocol.ts: bearer auth; the default { code, message } envelope.
-- - errors.ts: UnknownArgocdError, ArgocdParseError.
return {
  name = "argocd",
  title = "Argocd",
  base_url = {
    default = "https://localhost:8080",
    option = "base_url",
    env = "ARGOCD_SERVER",
  },
  auth = { kind = "bearer", from = "token", env = "ARGOCD_TOKEN" },
  unknown_tag = "UnknownArgocdError",
  parse_tag = "ArgocdParseError",
}
