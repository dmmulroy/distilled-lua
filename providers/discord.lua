-- Discord's provider spec.
--
-- Mirrors Distilled's hand-written Discord glue (packages/discord/src/):
-- - credentials.ts: the token from DISCORD_BOT_TOKEN, else DISCORD_TOKEN; the token type
--   from DISCORD_TOKEN_TYPE, default Bot ("bearer" in any case is Bearer, anything else
--   Bot); the base URL from DISCORD_API_URL, default https://discord.com/api/v10.
-- - protocol.ts: Authorization "<type> <token>"; failures are { code, message |
--   error_description | error }; the unknown error carries the body's `errors`.
-- - errors.ts: UnknownDiscordError, DiscordParseError.
return {
  name = "discord",
  title = "Discord",
  base_url = {
    default = "https://discord.com/api/v10",
    option = "base_url",
    env = "DISCORD_API_URL",
  },
  options = {
    token = { secret = true, env = { "DISCORD_BOT_TOKEN", "DISCORD_TOKEN" }, required = true },
    token_type = {
      env = "DISCORD_TOKEN_TYPE",
      default = "Bot",
      choices = { "Bot", "Bearer" },
      ignore_case = true,
      invalid = "default",
    },
  },
  headers = { Authorization = "{token_type} {token}" },
  error_envelope = { code = "/code", message = { "/message", "/error_description", "/error" } },
  unknown_fields = { errors = "/errors" },
  unknown_tag = "UnknownDiscordError",
  parse_tag = "DiscordParseError",
}
