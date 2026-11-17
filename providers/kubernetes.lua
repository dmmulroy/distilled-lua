-- Kubernetes' provider spec.
--
-- Mirrors Distilled's hand-written Kubernetes glue (packages/kubernetes/src/):
-- - credentials.ts: the token from KUBERNETES_TOKEN; the API server from
--   KUBERNETES_API_URL (required, no default).
-- - protocol.ts: bearer auth; the unknown error carries the Status object's `reason`.
-- - errors.ts: UnknownKubernetesError, KubernetesParseError.
return {
  name = "kubernetes",
  title = "Kubernetes",
  base_url = { option = "base_url", env = "KUBERNETES_API_URL" },
  auth = { kind = "bearer", from = "token", env = "KUBERNETES_TOKEN" },
  unknown_fields = { reason = "/reason" },
  unknown_tag = "UnknownKubernetesError",
  parse_tag = "KubernetesParseError",
}
