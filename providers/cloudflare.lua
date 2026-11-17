-- Cloudflare's provider spec: one spec for the package's models (one module per API
-- resource, `require("cloudflare.d1")`, as Distilled's one TS module per resource).
--
-- The models say they speak the v4 envelope protocol (service trait
-- com.cloudflare.protocols#v4Json), so the generator applies gen/cloudflare.lua and the
-- clients use distilled.protocol.cloudflare (a port of packages/cloudflare/src/
-- protocol.ts, credentials.ts, errors.ts, pagination.ts and jurisdiction.ts). Auth is
-- the protocol's: api_token, or api_key + email, else CLOUDFLARE_API_TOKEN or
-- CLOUDFLARE_API_KEY + CLOUDFLARE_EMAIL.
--
-- Member names stay as the wire spells them (snake_case, as Cloudflare's own docs);
-- Distilled's TS surface camelCases them.
return {
  name = "cloudflare",
  title = "Cloudflare",
  base_url = {
    default = "https://api.cloudflare.com/client/v4",
    option = "base_url",
    env = "CLOUDFLARE_API_BASE_URL",
  },
  auth = { kind = "none" },
  unknown_tag = "UnknownCloudflareError",
  parse_tag = "CloudflareParseError",
  naming = { members = "wire" },
  pagination = { items_fallback = "result" },
  -- every model speaks the envelope, also k2 (hand-written, no service shape to say so)
  protocol = "distilled.protocol.cloudflare",
}
