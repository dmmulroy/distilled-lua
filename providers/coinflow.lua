-- Coinflow's provider spec.
--
-- Mirrors Distilled's hand-written Coinflow glue (packages/coinflow/src/):
-- - credentials.ts: the key from COINFLOW_API_KEY; the environment from COINFLOW_ENV,
--   sandbox (default) or production (anything else is a ConfigError), picking the base
--   URL, unless COINFLOW_API_BASE_URL gives it; trailing slashes removed.
-- - protocol.ts: the raw key in Authorization; failures are { msg | message | error }.
-- - errors.ts: UnknownCoinflowError, CoinflowParseError.
return {
  name = "coinflow",
  title = "Coinflow",
  base_url = {
    default = "{environment}",
    option = "base_url",
    env = "COINFLOW_API_BASE_URL",
    trim_slash = true,
  },
  auth = { kind = "header", header = "Authorization", from = "api_key", env = "COINFLOW_API_KEY" },
  options = {
    environment = {
      env = "COINFLOW_ENV",
      default = "sandbox",
      choices = {
        sandbox = "https://api-sandbox.coinflow.cash/api",
        production = "https://api.coinflow.cash/api",
      },
    },
  },
  error_envelope = { message = { "/msg", "/message", "/error" } },
  unknown_tag = "UnknownCoinflowError",
  parse_tag = "CoinflowParseError",
}
