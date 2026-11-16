-- distilled: the top-level entry point.
local json = require("distilled.json")
local secret = require("distilled.secret")
local Scope = require("distilled.scope")
local errors = require("distilled.errors")
local compat = require("distilled.compat")

local distilled = {}

distilled.null = json.null
-- distilled.secret is the secret module, and calling it wraps: distilled.secret(key).
distilled.secret = secret
distilled.errors = errors
distilled.json = json
distilled.Scope = Scope

--- distilled.check(value, err) -> value, or raises tostring(err) as a string.
-- For callers that do want to raise (for example a Rex action boundary): gopher-lua's
-- assert rejects table messages, and Rex prints a raised table as "table: 0x...".
function distilled.check(value, err)
  if value == nil or (value == false and err ~= nil) then
    local message
    if err == nil then
      message = "distilled.check: no value and no error"
    else
      message = tostring(err)
    end
    compat.raise(message, 2)
  end
  return value
end

--- distilled.scope(fn) -> ...: a bracket around a block of work (see Scope.with).
function distilled.scope(fn)
  return Scope.with(fn)
end

return distilled
