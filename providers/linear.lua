-- Linear's provider spec: a GraphQL-only package (no Smithy model).
--
-- Mirrors Distilled's hand-written Linear glue (packages/linear/src/):
-- - credentials.ts: a personal API key (LINEAR_API_KEY) is sent bare as
--   `Authorization: <key>`; an OAuth access token (LINEAR_ACCESS_TOKEN) as
--   `Authorization: Bearer <token>`; the API key wins when both are set; empty variables
--   count as unset; LINEAR_API_URL overrides https://api.linear.app.
-- - graphql-transport.ts: POST <base>/graphql (one trailing slash removed), the token
--   trimmed and no Authorization header when it is empty, Accept
--   `application/graphql-response+json, application/json`.
-- The span prefix, system and response headers come from the model's telemetry entry.
return {
  name = "linear",
  title = "Linear",
  graphql = {
    sdk = "Linear",
    url = {
      option = "base_url",
      env = "LINEAR_API_URL",
      default = "https://api.linear.app",
      path = "/graphql",
    },
    accept = "application/graphql-response+json, application/json",
    auth = {
      {
        option = "api_key",
        env = "LINEAR_API_KEY",
        header = "Authorization",
        trim = true,
        skip_empty = true,
      },
      {
        option = "access_token",
        env = "LINEAR_ACCESS_TOKEN",
        header = "Authorization",
        prefix = "Bearer ",
        trim = true,
        skip_empty = true,
      },
    },
    missing = "LINEAR_API_KEY (or LINEAR_ACCESS_TOKEN) environment variable is required",
    source = "packages/linear/src/credentials.ts, graphql-transport.ts",
  },
}
