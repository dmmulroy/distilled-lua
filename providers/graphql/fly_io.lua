-- Fly.io's GraphQL provider spec (the GraphQL part of the fly-io package: add-ons such
-- as Tigris and Redis). Module fly_io.graphql, Distilled's `@distilled.cloud/fly-io/GraphQL`.
--
-- Mirrors Distilled's hand-written Fly glue (packages/fly-io/src/):
-- - credentials.ts: the token from FLY_API_TOKEN, else FLY_IO_API_KEY (the REST
--   services' token), sent as `Authorization: Bearer <token>`.
-- - graphql-transport.ts: always POST https://api.fly.io/graphql (FLY_API_HOSTNAME points
--   the Machines REST API elsewhere and does not apply), Accept application/json; an HTTP
--   failure without GraphQL errors names the body's `message` or `error`.
return {
  name = "fly_io",
  title = "Fly",
  graphql = {
    sdk = "Fly",
    module = "fly_io.graphql",
    url = "https://api.fly.io/graphql",
    accept = "application/json",
    auth = {
      {
        option = "api_key",
        env = { "FLY_API_TOKEN", "FLY_IO_API_KEY" },
        header = "Authorization",
        prefix = "Bearer ",
      },
    },
    missing = "FLY_API_TOKEN (or FLY_IO_API_KEY) environment variable is required",
    http_detail = { "message", "error" },
    source = "packages/fly-io/src/credentials.ts, graphql-transport.ts",
  },
}
