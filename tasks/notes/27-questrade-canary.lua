-- Task 27's canary for Questrade: the refresh token is the canary key, and it travels in
-- the token URL's query (GET /oauth2/token?grant_type=refresh_token&refresh_token=...).
-- The redemption answers slowly, so `ps` samples curl while the token URL is in flight;
-- the redeemed access token is the key too, so it reaches dl serve in an authorization
-- header. Then a refused redemption (a second client with another token) and a typed
-- error.
--   verify/dl canary tasks/notes/27-questrade-canary.lua
local root = string.match(debug.getinfo(1, "S").source, "^@?(.*)/tasks/notes/[^/]*$") or "."
package.path = root .. "/clients/?.lua;" .. root .. "/clients/?/init.lua;" .. package.path

local canary = require("verify.lib.canary")
local serve = require("verify.lib.serve")
canary.check_env()

local host = canary.host()
local s = serve.client(host.transport, canary.url)
s.script("/oauth2/token", {
  {
    status = 200,
    delay = 1.5,
    json = {
      access_token = canary.key,
      refresh_token = "rotated-not-secret",
      api_server = canary.url .. "/q/v1/",
      expires_in = 1800,
      token_type = "Bearer",
    },
  },
  { status = 400, body = "<html>Bad Request</html>" },
})
s.script("/q/v1/accounts", { { status = 200, json = { accounts = {} } } })
s.script("/q/v1/time", { { status = 401, json = { code = 1017, message = "Access token is invalid" } } })

local Questrade = require("questrade")
local function client(token)
  return Questrade.new({
    refresh_token = token,
    login_url = canary.url,
    host = host,
    getenv = function()
      return nil
    end,
    tracing = { level = "debug", file = canary.trace_file },
    retry = "none",
  })
end

local c = client(canary.key)
canary.report("redeemed, then accounts", c:list_accounts({}))
canary.report("typed error", c:get_time({}))
canary.report("refused redemption", client(canary.key .. "-second"):list_accounts({}))
return "done"
