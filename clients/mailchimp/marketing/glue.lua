-- Mailchimp Marketing's data centre (packages/mailchimp/src/credentials.ts) and
-- problem-document errors (protocol.ts).
local compat = require("distilled.compat")
local errors = require("distilled.errors")
local json = require("distilled.json")
local secret = require("distilled.secret")

local glue = {}

-- errors.ts: a problem document on a status nothing maps is MailchimpApiError, anything
-- else UnknownMailchimpError; both carry the problem's type, title and instance
local PROBLEM_FIELDS = { "type", "title", "instance" }
local MailchimpApiError = errors.define({ tag = "MailchimpApiError", fields = PROBLEM_FIELDS })
local UnknownMailchimpError =
  errors.define({ tag = "UnknownMailchimpError", fields = PROBLEM_FIELDS })

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

local function problem_message(body)
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
  return message
end

function glue.error_envelope(body)
  local message = problem_message(body)
  if message == nil then
    return nil
  end
  return { message = message }
end

function glue.unknown_error(info)
  local body = info.body
  local problem = type(body) == "table" and body ~= json.null and not json.is_array(body)
  local function field(k)
    local v = problem and rawget(body, k) or nil
    return type(v) == "string" and v ~= "" and v or nil
  end
  local class = problem_message(body) ~= nil and MailchimpApiError or UnknownMailchimpError
  return errors.new(class, {
    status = info.status,
    code = info.code ~= nil and tostring(info.code) or nil,
    message = info.message,
    body = body,
    headers = info.headers,
    type = field("type"),
    title = field("title"),
    instance = field("instance"),
  })
end

return glue
