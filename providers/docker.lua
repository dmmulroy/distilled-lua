-- Docker Engine's provider spec.
--
-- Mirrors Distilled's hand-written Docker glue (packages/docker/src/):
-- - credentials.ts: an optional token from DOCKER_API_KEY; the base URL from
--   DOCKER_API_BASE_URL, default http://localhost/v1.56.
-- - protocol.ts: bearer auth only when a token is set.
-- - errors.ts: UnknownDockerError, DockerParseError.
return {
  name = "docker",
  title = "Docker",
  base_url = {
    default = "http://localhost/v1.56",
    option = "base_url",
    env = "DOCKER_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "DOCKER_API_KEY", optional = true },
  unknown_tag = "UnknownDockerError",
  parse_tag = "DockerParseError",
}
