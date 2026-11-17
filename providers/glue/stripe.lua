-- Stripe's error reading (packages/stripe/src/protocol.ts matchStripeError and
-- errors.ts). The classes are long-lived: defined once with the module.
local errors = require("distilled.errors")
local json = require("distilled.json")

local COMMON = { "doc_url", "request_log_url" }

local function class(tag, categories, fields, retryable)
  local all = {}
  for _, f in ipairs(COMMON) do
    all[#all + 1] = f
  end
  for _, f in ipairs(fields) do
    all[#all + 1] = f
  end
  return errors.define({ tag = tag, categories = categories, fields = all, retryable = retryable })
end

local CardError = class("CardError", { "BadRequestError" }, {
  "decline_code",
  "charge",
  "param",
  "advice_code",
  "network_advice_code",
  "network_decline_code",
  "payment_method_type",
})
local IdempotencyError = class("IdempotencyError", { "ConflictError" }, {})
local InvalidRequestError = class("InvalidRequestError", { "BadRequestError" }, { "param" })
local ApiError = class("ApiError", { "ServerError", "RetryableError" }, { "param" }, true)
local PaymentError = class(
  "PaymentError",
  { "BadRequestError" },
  { "decline_code", "charge", "param" }
)
local ExternalDependencyFailed = class(
  "ExternalDependencyFailed",
  { "ServerError", "RetryableError" },
  {},
  true
)

-- the same tag as the protocol's unknown error (rest.new unknown_tag): a body without
-- error.type below 500 is UnknownStripeError in Distilled, never a status-map class
local UnknownStripeError =
  errors.define({ tag = "UnknownStripeError", fields = { "type", "param" } })

local STRIPE_STATUS_MAP = { [402] = PaymentError, [424] = ExternalDependencyFailed }

local function str(v)
  return type(v) == "string" and v or nil
end

local glue = {}

function glue.classify_error(info)
  local body = info.body
  local e = type(body) == "table" and body ~= json.null and rawget(body, "error") or nil
  if type(e) ~= "table" or e == json.null or type(rawget(e, "type")) ~= "string" then
    if info.status >= 500 then
      return nil -- the shared path: InternalServerError "HTTP <status>"
    end
    return errors.new(
      UnknownStripeError,
      { status = info.status, body = body, headers = info.headers }
    )
  end
  local fields = {
    message = str(e.message),
    code = str(e.code),
    doc_url = str(e.doc_url),
    request_log_url = str(e.request_log_url),
    status = info.status,
    body = body,
    headers = info.headers,
  }
  local kind = e.type
  local target
  if kind == "card_error" then
    target = CardError
    for _, k in ipairs({
      "decline_code",
      "charge",
      "param",
      "advice_code",
      "network_advice_code",
      "network_decline_code",
      "payment_method_type",
    }) do
      fields[k] = str(e[k])
    end
  elseif kind == "idempotency_error" then
    target = IdempotencyError
  elseif kind == "invalid_request_error" then
    target = InvalidRequestError
    fields.param = str(e.param)
  elseif kind == "api_error" then
    target = ApiError
    fields.param = str(e.param)
  else
    target = STRIPE_STATUS_MAP[info.status]
    if target == nil then
      return nil -- the shared status map, 5xx, then UnknownStripeError (type, param)
    end
    fields.decline_code = str(e.decline_code)
    fields.charge = str(e.charge)
    fields.param = str(e.param)
  end
  return errors.new(target, fields)
end

return glue
