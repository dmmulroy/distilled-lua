-- E2B envd's host (packages/e2b/src/credentials.ts envdBaseUrlFor): E2B Cloud
-- (domain e2b.app) serves every sandbox at https://sandbox.<domain>, routed by the
-- E2b-Sandbox-Id header; any other domain at https://<port>-<sandbox_id>.<domain>.
-- A base_url option, when given, wins.
local glue = {}

local SHARED_SANDBOX_HOST_DOMAINS = { ["e2b.app"] = true }

function glue.base_url(s)
  if type(s.base_url) == "string" and s.base_url ~= "" then
    return s.base_url
  end
  local domain = s.domain or "e2b.app"
  if SHARED_SANDBOX_HOST_DOMAINS[domain] then
    return "https://sandbox." .. domain
  end
  return "https://" .. tostring(s.port or "49983") .. "-" .. tostring(s.sandbox_id) .. "." .. domain
end

return glue
