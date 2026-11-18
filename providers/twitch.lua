-- Twitch's provider spec: one spec for the package's 29 models (one module per page of the
-- API reference, `require("twitch.chat")`, as Distilled's one TS module per page).
--
-- Mirrors Distilled's hand-written Twitch glue (packages/twitch/src/):
-- - credentials.ts: a user or app access token from TWITCH_ACCESS_TOKEN, sent as
--   `Authorization: Bearer`, and the app's client ID from TWITCH_CLIENT_ID, sent as
--   `Client-Id` (Helix requires both; the client ID must be the one the token was issued
--   to). Base URL from TWITCH_API_BASE_URL, default https://api.twitch.tv/helix.
-- - protocol.ts: failures are `{ error, status, message }`, read by the default envelope.
-- - errors.ts: UnknownTwitchError, TwitchParseError.
-- - scripts/generate.ts: wire member names are the surface (snake_case already).
return {
  name = "twitch",
  title = "Twitch",
  base_url = {
    default = "https://api.twitch.tv/helix",
    option = "base_url",
    env = "TWITCH_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "access_token", env = "TWITCH_ACCESS_TOKEN" },
  options = { client_id = { env = "TWITCH_CLIENT_ID" } },
  headers = { ["Client-Id"] = "{client_id}" },
  unknown_tag = "UnknownTwitchError",
  parse_tag = "TwitchParseError",
  naming = { members = "wire" },
}
