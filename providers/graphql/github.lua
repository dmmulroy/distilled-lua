-- GitHub's GraphQL provider spec (the GraphQL part of the github package; providers/
-- github.lua is the REST spec). Module github.graphql, Distilled's
-- `@distilled.cloud/github/GraphQL`.
--
-- Mirrors Distilled's hand-written GitHub glue (packages/github/src/):
-- - credentials.ts: the token from GITHUB_TOKEN, else GH_TOKEN, sent as
--   `Authorization: Bearer <token>`; the API root from GITHUB_API_URL, default
--   https://api.github.com; the User-Agent from GITHUB_USER_AGENT, default
--   distilled.cloud-github (GitHub rejects requests without one).
-- - graphql-transport.ts graphqlUrl: the REST root without a trailing slash and without
--   a trailing /v3 (GitHub Enterprise Server: <host>/api/v3 -> <host>/api/graphql), then
--   /graphql. Accept application/json. GitHub puts an error's code in a top-level `type`,
--   moved to extensions.code; an HTTP failure with a REST-style `{ message }` body names it.
-- Not mirrored: GitHub App auth (app.ts, an RS256 JWT).
return {
  name = "github",
  title = "GitHub",
  graphql = {
    sdk = "GitHub",
    module = "github.graphql",
    url = {
      option = "base_url",
      env = "GITHUB_API_URL",
      default = "https://api.github.com",
      path = "/graphql",
      strip = "/v3",
    },
    accept = "application/json",
    auth = {
      {
        option = "token",
        env = { "GITHUB_TOKEN", "GH_TOKEN" },
        header = "Authorization",
        prefix = "Bearer ",
      },
    },
    missing = "GITHUB_TOKEN (or GH_TOKEN) environment variable is required",
    user_agent = { env = "GITHUB_USER_AGENT", default = "distilled.cloud-github" },
    error_type_code = true,
    http_detail = { "message" },
    source = "packages/github/src/credentials.ts, graphql-transport.ts",
  },
}
