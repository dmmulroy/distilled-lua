-- Zendesk's subdomain (packages/zendesk/src/credentials.ts originFromSubdomain) and the
-- email that Basic auth needs.
local errors = require("distilled.errors")

local glue = {}

function glue.settings(s)
  if type(s.subdomain) == "string" then
    local host = string.gsub(s.subdomain, "^%s+", "")
    host = string.gsub(host, "%s+$", "")
    host = string.gsub(host, "^[Hh][Tt][Tt][Pp][Ss]?://", "")
    host = string.gsub(host, "/+$", "")
    if string.find(host, ".", 1, true) then
      s.subdomain = "https://" .. host
    else
      s.subdomain = "https://" .. host .. ".zendesk.com"
    end
  end
  if s.access_token == nil and s.api_token ~= nil and (s.email == nil or s.email == "") then
    return nil,
      errors.new("ConfigError", {
        message = "Zendesk: pass email (or set ZENDESK_EMAIL) with api_token",
        key = "email",
      })
  end
  return s
end

return glue
