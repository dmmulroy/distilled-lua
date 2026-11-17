-- Mailchimp Transactional (Mandrill) glue (packages/mailchimp/src/protocol.ts
-- MailchimpTransactionalProtocol and errors.ts MailchimpTransactionalError): the key
-- travels as the `key` body member of every call, and failures are
-- { status = "error", code, name, message }.
local errors = require("distilled.errors")
local json = require("distilled.json")

local glue = {}

-- a status the operation and the core map do not cover (long-lived class)
local MailchimpTransactionalError =
  errors.define({ tag = "MailchimpTransactionalError", fields = { "name" } })

local function text(v)
  return type(v) == "string" and v ~= "" and v or nil
end

local function failure(body)
  if
    type(body) == "table"
    and body ~= json.null
    and not json.is_array(body)
    and rawget(body, "status") == "error"
  then
    return body
  end
  return nil
end

-- encode: { ...input, key = creds.apiKey } (the secret is unwrapped by request.build)
function glue.transform_input(input, _, settings)
  local out = {}
  for k, v in pairs(input or {}) do
    out[k] = v
  end
  out.key = settings.api_key
  return out
end

-- errorEnvelope: "name: message" (or either alone), a numeric code
function glue.error_envelope(body)
  local f = failure(body)
  if not f then
    return nil
  end
  local name, message = text(rawget(f, "name")), text(rawget(f, "message"))
  local m = (name and message) and (name .. ": " .. message) or (name or message)
  if m == nil then
    return nil
  end
  local code = rawget(f, "code")
  return { message = m, code = type(code) == "number" and code or nil }
end

-- unknownError: MailchimpTransactionalError for a Transactional failure, else the
-- default unknown error (UnknownMailchimpError)
function glue.unknown_error(info)
  local f = failure(info.body)
  if not f then
    return nil
  end
  return errors.new(MailchimpTransactionalError, {
    status = info.status,
    code = type(info.code) == "number" and info.code or nil,
    name = text(rawget(f, "name")),
    message = info.message,
    body = info.body,
  })
end

return glue
