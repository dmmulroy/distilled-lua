-- Mailchimp Marketing's data centre (packages/mailchimp/src/credentials.ts) and
-- problem-document errors (protocol.ts).
local compat = require("distilled.compat")
local errors = require("distilled.errors")
local json = require("distilled.json")
local secret = require("distilled.secret")

local glue = {}

function glue.settings(s)
  if
    (s.server_prefix == nil or s.server_prefix == "") and (s.base_url == nil or s.base_url == "")
  then
    local key = tostring(secret.unwrap(s.api_key))
    local dc = string.match(key, "%-(%a+%d+)$")
    if not dc then
      return nil,
        errors.new("ConfigError", {
          message = "Mailchimp API key has no data-centre suffix (expected <key>-<dc>, e.g. ...-us21);"
            .. " pass server_prefix",
          key = "server_prefix",
        })
    end
    s.server_prefix = string.lower(dc)
  end
  return s
end

function glue.error_envelope(body)
  if type(body) ~= "table" or body == json.null or json.is_array(body) then
    return nil
  end
  local function text(v)
    return type(v) == "string" and v ~= "" and v or nil
  end
  local message = text(rawget(body, "detail")) or text(rawget(body, "title"))
  local list = rawget(body, "errors")
  if message and type(list) == "table" and json.is_array(list) then
    local parts = {}
    for _, e in ipairs(list) do
      if type(e) == "table" and e ~= json.null then
        local field, m = text(rawget(e, "field")), text(rawget(e, "message"))
        if m then
          parts[#parts + 1] = field and (field .. ": " .. m) or m
        end
      end
    end
    if #parts > 0 then
      message = message .. " (" .. compat.concat(parts, "; ") .. ")"
    end
  end
  return { message = message }
end

return glue
