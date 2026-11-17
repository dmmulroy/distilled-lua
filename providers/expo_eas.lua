-- Expo Application Services' provider spec: a GraphQL-only package (no Smithy model).
--
-- Mirrors Distilled's hand-written EAS glue (packages/expo-eas/src/):
-- - credentials.ts: a personal or organization access token from EXPO_TOKEN, sent as
--   `Authorization: Bearer <token>`; EXPO_API_URL overrides https://api.expo.dev
--   (https://staging-api.expo.dev targets staging).
-- - graphql-transport.ts: POST <base>/graphql (one trailing slash removed), Accept
--   application/json; an HTTP failure without GraphQL errors names the body's `message`.
-- Errors are classified by `extensions.errorCode` (the runtime reads `code`, then
-- `errorCode`, as core graphql.ts does).
return {
  name = "expo_eas",
  title = "Eas",
  graphql = {
    sdk = "Eas",
    url = {
      option = "base_url",
      env = "EXPO_API_URL",
      default = "https://api.expo.dev",
      path = "/graphql",
    },
    accept = "application/json",
    auth = {
      { option = "access_token", env = "EXPO_TOKEN", header = "Authorization", prefix = "Bearer " },
    },
    missing = "EXPO_TOKEN environment variable is required",
    http_detail = { "message" },
    source = "packages/expo-eas/src/credentials.ts, graphql-transport.ts",
  },
}
