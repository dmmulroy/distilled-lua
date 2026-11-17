-- Intended differences between the Lua Cloudflare client and Distilled's TS SDK, as
-- normalisations applied to both outcomes before compare.lua compares them. Each one
-- returns its reason, which the report counts, so none hides silently.
--
-- Not normalised here because the projection is the comparison itself (lib.to_ts): Lua
-- keeps wire names and every key the API sends (keys.lua: undeclared keys pass
-- through); Distilled camelCases members, renames opaque content by the key
-- dictionary, and keeps only the active case's keys of a union.
local intended = {}

local PARSE_MESSAGE = "CloudflareParseError message: Distilled's class has no message field "
  .. "(body and cause only); Lua's names the operation and the mismatch. Compared by the "
  .. "cause's path and expectation instead"

--- intended.normalize(case, lua, ts) -> lua, ts, reason | nil
function intended.normalize(_, lua, ts)
  local le, te = lua.error, ts.error
  if le and te and le.tag == "CloudflareParseError" and te.tag == "CloudflareParseError" then
    le.message = nil
    te.message = nil
    return lua, ts, PARSE_MESSAGE
  end
  return lua, ts, nil
end

return intended
