-- Railway's provider spec: a GraphQL-only package (no Smithy model).
--
-- Mirrors Distilled's hand-written Railway glue (packages/railway/src/):
-- - credentials.ts: an account/team token (RAILWAY_API_TOKEN, else RAILWAY_TOKEN, the
--   Railway CLI's name) is sent as `Authorization: Bearer <token>`; a project token
--   (RAILWAY_PROJECT_TOKEN) as `Project-Access-Token: <token>`; the account token wins
--   when both kinds are set; RAILWAY_API_URL overrides https://backboard.railway.com.
-- - graphql-transport.ts: POST <base>/graphql/v2 (one trailing slash removed), the token
--   trimmed and no auth header when it is empty, Accept
--   `application/graphql-response+json, application/json`.
-- Distilled reads RAILWAY_TOKEN only from the environment; here it is a second variable of
-- the `api_token` option.
return {
  name = "railway",
  title = "Railway",
  graphql = {
    sdk = "Railway",
    url = {
      option = "base_url",
      env = "RAILWAY_API_URL",
      default = "https://backboard.railway.com",
      path = "/graphql/v2",
    },
    accept = "application/graphql-response+json, application/json",
    auth = {
      {
        option = "api_token",
        env = { "RAILWAY_API_TOKEN", "RAILWAY_TOKEN" },
        header = "Authorization",
        prefix = "Bearer ",
        trim = true,
        skip_empty = true,
      },
      {
        option = "project_token",
        env = "RAILWAY_PROJECT_TOKEN",
        header = "Project-Access-Token",
        trim = true,
        skip_empty = true,
      },
    },
    missing = "RAILWAY_API_TOKEN (or RAILWAY_TOKEN / RAILWAY_PROJECT_TOKEN) environment variable is required",
    source = "packages/railway/src/credentials.ts, graphql-transport.ts",
  },
}
