-- The Lua side's fixed environment for dl conform: the same credentials and base URL the
-- Node side uses (verify/conform/node/distilled.mjs), a capturing transport, no retry.
local errors = require("distilled.errors")

local env = {}

env.BASE_URL = "https://api.conform.test/v2"
env.API_KEY = "conform-key-0123"

-- env.capture.req is the last request a client built (state in a table: gopher-lua)
env.capture = {}

local function capture_transport(req)
  env.capture.req = req
  return nil, errors.new("TransportError", { message = "conform: request captured, not sent" })
end

--- env.client(ctx [, overrides]) -> a client of the provider's generated class
function env.client(ctx, overrides)
  local opts = {
    api_key = env.API_KEY,
    base_url = env.BASE_URL,
    transport = capture_transport,
    sleep = function() end,
    retry = "none",
  }
  for k, v in pairs(overrides or {}) do
    opts[k] = v
  end
  return ctx.class.new(opts)
end

return env
