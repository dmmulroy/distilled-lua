-- Neon's provider spec: everything about Neon the model does not say.
--
-- Mirrors Distilled's hand-written Neon glue (packages/neon/src/): protocol.ts (bearer
-- auth, base URL, the default lenient `{ code?, message }` error envelope), credentials.ts
-- (NEON_API_KEY, NEON_API_BASE_URL, https://console.neon.tech/api/v2) and errors.ts
-- (UnknownNeonError, NeonParseError). Neon keeps wire names on the Lua surface, as
-- Distilled's Neon SDK does.
return {
  name = "neon",
  title = "Neon",
  base_url = {
    default = "https://console.neon.tech/api/v2",
    option = "base_url",
    env = "NEON_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "NEON_API_KEY" },
  unknown_tag = "UnknownNeonError",
  parse_tag = "NeonParseError",
  naming = { members = "wire" },
  pagination = { items_fallback = "items" },
  -- CreateProjectBranchFunctionDeployment uploads a ZIP as multipart/form-data, which
  -- request.build does not encode yet: the method exists and returns SdkError.
  allow_unsupported = { "multipart" },
}
