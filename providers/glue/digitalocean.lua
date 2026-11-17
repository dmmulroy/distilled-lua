-- DigitalOcean's per-server base URL (packages/digitalocean/src/protocol.ts baseUrlFor).
-- route.server is the operation's server name (task 12); nil is the main API.
local errors = require("distilled.errors")

local DEFAULT_API_BASE_URL = "https://api.digitalocean.com"

local glue = {}

function glue.base_url(s, route)
  local server = route and route.server
  if server == nil then
    return s.base_url or DEFAULT_API_BASE_URL
  elseif server == "inference" then
    return s.inference_base_url
  elseif server == "actions" then
    return s.actions_base_url
  end
  return nil,
    errors.new("SdkError", {
      message = 'DigitalOcean operation runs on server "'
        .. tostring(server)
        .. '", which has no base URL in the options',
    })
end

return glue
