-- Convex's provider spec (models management, deployment and functions).
--
-- Mirrors Distilled's hand-written Convex glue (packages/convex/src/):
-- - credentials.ts (management model): the token from CONVEX_ACCESS_TOKEN; the base URL
--   from CONVEX_API_BASE_URL, default https://api.convex.dev/v1.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownConvexError, ConvexParseError.
--
-- - protocol.ts ConvexDeploymentProtocol (model deployment): Authorization
--   "Convex <token>" (the same token, CONVEX_ACCESS_TOKEN), base URL
--   <deploymentUrl>/api/v1; ConvexFunctionsProtocol (model functions): no auth, base URL
--   <deploymentUrl>/api. deploymentUrl (fromDeployment's url) has no environment
--   variable and is trimmed of trailing slashes; without it the call is a ConfigError.
return {
  name = "convex",
  title = "Convex",
  base_url = {
    default = "https://api.convex.dev/v1",
    option = "base_url",
    env = "CONVEX_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "access_token", env = "CONVEX_ACCESS_TOKEN" },
  models = {
    override = {
      deployment = {
        base_url = { default = "{deployment_url}/api/v1", env = false },
        auth = {
          kind = "header",
          header = "authorization",
          prefix = "Convex ",
          from = "access_token",
          env = "CONVEX_ACCESS_TOKEN",
        },
        options = {
          deployment_url = {
            trim_slash = true,
            doc = "the deployment, e.g. https://x.convex.cloud",
          },
        },
      },
      functions = {
        base_url = { default = "{deployment_url}/api", env = false },
        auth = false,
        options = {
          deployment_url = {
            trim_slash = true,
            doc = "the deployment, e.g. https://x.convex.cloud",
          },
        },
      },
    },
  },
  unknown_tag = "UnknownConvexError",
  parse_tag = "ConvexParseError",
}
