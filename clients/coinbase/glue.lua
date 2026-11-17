-- Coinbase CDP's request signing and error reading (packages/coinbase/src/protocol.ts,
-- errors.ts, credentials.ts).
--
-- sign: every request carries `Authorization: Bearer <JWT>`, minted per request:
--   header  {"alg":"ES256"|"EdDSA","kid":<key id>,"typ":"JWT","nonce":<32 hex>}
--   claims  {"sub":<key id>,"iss":"cdp","aud":["cdp_service"],"nbf":now,"exp":now+120,
--            "uri":"<METHOD> <host><path>"}   (the label-filled path, no query string)
-- The algorithm follows the secret (resolveSigningKey): text with "-----BEGIN" is a PEM
-- key signed ES256; otherwise the base64 text must decode to 64 bytes (Ed25519 seed ||
-- public key), signed EdDSA with the seed. `now` is host.epoch(), the nonce 16 bytes from
-- host.random (Distilled: crypto.randomBytes(16)). ES256 signatures here are RFC 6979
-- (deterministic); node:crypto's are randomized, so only EdDSA tokens can equal
-- Distilled's byte for byte (both verify with the same public key).
--
-- Parsed keys are cached by the SHA-256 of the secret (never the secret itself), at most
-- KEY_CACHE_MAX entries: parsing a PEM and building its tables costs more than a
-- signature (verify/features/crypto.md).
--
-- classify_error: matchError. By errorType (ERROR_TYPE_MAP, then the standard types to
-- the core classes), then by status (core HTTP_STATUS_MAP, 402 PaymentRequired, unmapped
-- 5xx InternalServerError), else UnknownCoinbaseError. accept_failure: a failure body
-- with an `isValid` or `success` key is a success value (policy validation results).
local crypto = require("distilled.crypto")
local errors = require("distilled.errors")
local json = require("distilled.json")
local retry = require("distilled.retry")
local secret = require("distilled.secret")

local glue = {}

---------------------------------------------------------------------------------------
-- signing
---------------------------------------------------------------------------------------

local KEY_CACHE_MAX = 16
local key_cache, key_cache_size = {}, 0

local function config_error(message, key)
  return errors.new("ConfigError", { message = message, key = key })
end

local function invalid_key(detail, cause)
  local why = errors.is(cause) and cause.message or tostring(cause)
  return config_error(detail .. ": " .. tostring(why), "api_key_secret")
end

-- Buffer.from(text, "base64"): both alphabets, stops at "=", skips other characters,
-- and drops a trailing lone character
local function lenient_base64(text)
  local cut = string.find(text, "=", 1, true)
  if cut then
    text = string.sub(text, 1, cut - 1)
  end
  text = string.gsub(string.gsub(string.gsub(text, "%-", "+"), "_", "/"), "[^%w+/]", "")
  local extra = #text % 4
  if extra == 1 then
    text = string.sub(text, 1, -2)
  elseif extra > 1 then
    text = text .. string.rep("=", 4 - extra)
  end
  return crypto.base64.decode(text)
end

-- resolveSigningKey -> { alg, key } | nil, ConfigError
local function resolve_key(plain)
  if string.find(plain, "-----BEGIN", 1, true) then
    local key, err = require("distilled.crypto.pem").private_key(plain)
    if not key then
      return nil, invalid_key("The CDP API Key Secret is not a valid EC PEM private key", err)
    end
    return { alg = "ES256", key = key }
  end
  local raw = lenient_base64(plain)
  if raw and #raw == 64 then
    local key, err = require("distilled.crypto.ed25519").private_key(string.sub(raw, 1, 32))
    if not key then
      return nil, invalid_key("The CDP API Key Secret is not a valid Ed25519 private key", err)
    end
    return { alg = "EdDSA", key = key }
  end
  return nil,
    config_error(
      "Unsupported CDP API Key Secret format. Expected EC PEM or Ed25519 base64.",
      "api_key_secret"
    )
end

local function signing_key(plain)
  local id = crypto.sha256(plain)
  local hit = key_cache[id]
  if hit then
    return hit
  end
  local resolved, err = resolve_key(plain)
  if not resolved then
    return nil, err
  end
  if key_cache_size >= KEY_CACHE_MAX then
    key_cache, key_cache_size = {}, 0
  end
  key_cache[id] = resolved
  key_cache_size = key_cache_size + 1
  return resolved
end

-- crypto.randomBytes(16).toString("hex"), from host.random
local function nonce(random)
  local out = {}
  for i = 1, 16 do
    out[i] = string.format("%02x", math.floor(random() * 256) % 256)
  end
  return table.concat(out)
end

-- new URL(url).host .. pathname: lower-case host, default port dropped, "/" for an
-- empty path, no query or fragment. nil when the URL is not absolute.
local function host_and_path(target)
  local scheme, rest = string.match(target, "^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    return nil
  end
  scheme = string.lower(scheme)
  local authority = string.match(rest, "^[^/?#]*")
  local path = string.match(string.sub(rest, #authority + 1), "^[^?#]*")
  authority = string.lower((string.gsub(authority, "^.*@", "")))
  if authority == "" then
    return nil
  end
  local port = string.match(authority, ":(%d*)$")
  if port then
    local default = (scheme == "https" and "443") or (scheme == "http" and "80") or nil
    if port == "" or port == default then
      authority = string.sub(authority, 1, #authority - #port - 1)
    end
  end
  if path == "" then
    path = "/"
  end
  return authority .. path
end

function glue.sign(req, s, info)
  local jws = require("distilled.crypto.jws")
  local jwt = require("distilled.crypto.jwt")
  local plain = s.api_key_secret ~= nil and secret.unwrap(s.api_key_secret) or nil
  if type(plain) ~= "string" or plain == "" then
    return nil,
      config_error("CDP_API_KEY_SECRET environment variable is required", "api_key_secret")
  end
  local id = s.api_key_id ~= nil and secret.unwrap(s.api_key_id) or nil
  if id == nil or id == "" then
    return nil,
      config_error(
        "CDP_API_KEY_ID (or CDP_API_KEY_NAME) environment variable is required",
        "api_key_id"
      )
  end
  id = tostring(id)
  local uri = host_and_path(req.url)
  if uri == nil then
    return nil,
      config_error(
        "Coinbase apiBaseUrl must be an absolute URL such as https://api.cdp.coinbase.com/platform; got "
          .. json.encode(tostring(info.base_url)),
        "base_url"
      )
  end
  local resolved, kerr = signing_key(plain)
  if not resolved then
    return nil, kerr
  end
  local host = info.host or {}
  local now = math.floor((host.epoch or os.time)())
  local random = host.random or require("distilled.host").default().random
  local token, err = jwt.encode({
    key = resolved.key,
    alg = resolved.alg,
    header = jws.object("kid", id, "typ", "JWT", "nonce", nonce(random)),
    claims = jws.object(
      "sub",
      id,
      "iss",
      "cdp",
      "aud",
      { "cdp_service" },
      "nbf",
      now,
      "exp",
      now + 120,
      "uri",
      req.method .. " " .. uri
    ),
  })
  if not token then
    -- a key that parses but cannot sign with its algorithm (an Ed25519 or RSA PEM is
    -- routed to ES256)
    return nil, invalid_key("The CDP API Key Secret cannot sign a " .. resolved.alg .. " JWT", err)
  end
  req.headers["authorization"] = "Bearer " .. token
  return req
end

---------------------------------------------------------------------------------------
-- errors (errors.ts)
---------------------------------------------------------------------------------------

local FIELDS = { "error_type", "error_message", "correlation_id", "error_link" }

local function class(tag, categories, retryable)
  return errors.define({
    tag = tag,
    categories = categories,
    retryable = retryable,
    fields = FIELDS,
  })
end

local BAD = { "BadRequestError" }
local CONFLICT = { "ConflictError" }
local QUOTA = { "QuotaError" }
local AUTH = { "AuthError" }
local ABORTED = { "AbortedError" }
local NOT_FOUND = { "NotFoundError" }

local PaymentRequired = class("PaymentRequired", BAD)

-- errorType -> class (ERROR_TYPE_MAP)
local ERROR_TYPE_MAP = {
  already_exists = class("AlreadyExists", { "AlreadyExistsError" }),
  idempotency_error = class("IdempotencyError", CONFLICT),
  policy_in_use = class("PolicyInUse", CONFLICT),
  faucet_limit_exceeded = class("FaucetLimitExceeded", QUOTA),
  account_limit_exceeded = class("AccountLimitExceeded", QUOTA),
  guest_transaction_limit = class("GuestTransactionLimit", QUOTA),
  guest_transaction_count = class("GuestTransactionCount", QUOTA),
  payment_method_required = PaymentRequired,
  payment_required = PaymentRequired,
  settlement_failed = class("SettlementFailed", { "ServerError" }),
  invalid_signature = class("InvalidSignature", BAD),
  invalid_sql_query = class("InvalidSqlQuery", BAD),
  malformed_transaction = class("MalformedTransaction", BAD),
  network_not_tradable = class("NetworkNotTradable", BAD),
  timed_out = class("TimedOut", { "TimeoutError" }, true),
  client_closed_request = class("ClientClosedRequest", ABORTED),
  request_canceled = class("RequestCanceled", ABORTED),
  policy_violation = class("PolicyViolation", BAD),
  insufficient_balance = class("InsufficientBalance", BAD),
  account_not_ready = class("AccountNotReady", { "RetryableError" }, true),
  mfa_required = class("MfaRequired", AUTH),
  mfa_already_enrolled = class("MfaAlreadyEnrolled", CONFLICT),
  mfa_invalid_code = class("MfaInvalidCode", AUTH),
  mfa_flow_expired = class("MfaFlowExpired", AUTH),
  mfa_not_enrolled = class("MfaNotEnrolled", BAD),
  guest_permission_denied = class("GuestPermissionDenied", AUTH),
  guest_region_forbidden = class("GuestRegionForbidden", AUTH),
  phone_number_verification_expired = class("PhoneNumberVerificationExpired", BAD),
  document_verification_failed = class("DocumentVerificationFailed", BAD),
  recipient_allowlist_violation = class("RecipientAllowlistViolation", BAD),
  recipient_allowlist_pending = class("RecipientAllowlistPending", BAD),
  travel_rules_recipient_violation = class("TravelRulesRecipientViolation", BAD),
  travel_rules_field_missing = class("TravelRulesFieldMissing", BAD),
  source_account_invalid = class("SourceAccountInvalid", BAD),
  target_account_invalid = class("TargetAccountInvalid", BAD),
  source_account_not_found = class("SourceAccountNotFound", NOT_FOUND),
  target_account_not_found = class("TargetAccountNotFound", NOT_FOUND),
  source_asset_not_supported = class("SourceAssetNotSupported", BAD),
  target_asset_not_supported = class("TargetAssetNotSupported", BAD),
  transfer_asset_not_supported = class("TransferAssetNotSupported", BAD),
  asset_mismatch = class("AssetMismatch", BAD),
  target_email_invalid = class("TargetEmailInvalid", BAD),
  target_onchain_address_invalid = class("TargetOnchainAddressInvalid", BAD),
  transfer_amount_invalid = class("TransferAmountInvalid", BAD),
  metadata_too_many_entries = class("MetadataTooManyEntries", BAD),
  metadata_key_too_long = class("MetadataKeyTooLong", BAD),
  metadata_value_too_long = class("MetadataValueTooLong", BAD),
  order_quote_expired = class("OrderQuoteExpired", BAD),
  order_already_filled = class("OrderAlreadyFilled", CONFLICT),
  order_already_canceled = class("OrderAlreadyCanceled", CONFLICT),
}

-- the standard errorTypes -> the core classes (STANDARD_ERROR_TYPE_MAP)
local STANDARD_ERROR_TYPE_MAP = {
  bad_gateway = "BadGateway",
  forbidden = "Forbidden",
  internal_server_error = "InternalServerError",
  invalid_request = "BadRequest",
  not_found = "NotFound",
  rate_limit_exceeded = "TooManyRequests",
  service_unavailable = "ServiceUnavailable",
  unauthorized = "Unauthorized",
}

local UnknownCoinbaseError = errors.define({ tag = "UnknownCoinbaseError", fields = FIELDS })

local function field(body, name)
  local v = rawget(body, name)
  return v
end

-- Schema.decodeUnknownOption(CoinbaseErrorResponse): errorType and errorMessage strings,
-- correlationId and errorLink absent or strings
local function envelope(body)
  if type(body) ~= "table" or body == json.null or json.is_array(body) then
    return nil
  end
  local t, m = field(body, "errorType"), field(body, "errorMessage")
  local c, l = field(body, "correlationId"), field(body, "errorLink")
  if type(t) ~= "string" or type(m) ~= "string" then
    return nil
  end
  if (c ~= nil and type(c) ~= "string") or (l ~= nil and type(l) ~= "string") then
    return nil
  end
  return { error_type = t, error_message = m, correlation_id = c, error_link = l }
end

-- the first 200 characters (code points) of the raw body
local function head(text)
  local n, i = 0, 1
  while i <= #text do
    n = n + 1
    if n > 200 then
      return string.sub(text, 1, i - 1)
    end
    local b = string.byte(text, i)
    i = i + ((b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1)
  end
  return text
end

local function is_object(v)
  return type(v) == "table" and v ~= json.null and not json.is_array(v)
end

function glue.accept_failure(info)
  local body = info.body
  if is_object(body) and (rawget(body, "isValid") ~= nil or rawget(body, "success") ~= nil) then
    return true
  end
  return nil
end

function glue.classify_error(info)
  local status, body, headers = info.status, info.body, info.headers or {}
  local parsed = envelope(body)
  local message
  if parsed then
    message = parsed.error_message
  elseif type(body) == "string" then
    message = head(body)
  elseif body == nil then
    message = "" -- JSON.stringify(undefined) ?? ""
  else
    -- JSON.stringify(body); key order is sorted here (json.encode), not the wire's
    message = head(json.encode(body) or "")
  end
  local function props(extra)
    local f = extra or {}
    f.status = status
    f.body = body
    f.headers = info.headers
    if parsed then
      for k, v in pairs(parsed) do
        f[k] = v
      end
      f.code = parsed.error_type
    end
    return f
  end
  local retry_after = retry.parse_for_status(status, headers, info.now)

  if parsed then
    local typed = ERROR_TYPE_MAP[parsed.error_type]
    if typed then
      return errors.new(typed, props({ message = parsed.error_message }))
    end
    local standard = STANDARD_ERROR_TYPE_MAP[parsed.error_type]
    if standard then
      return errors.new(
        standard,
        props({ message = parsed.error_message, retry_after = retry_after })
      )
    end
  end
  local core = errors.STATUS_MAP[status]
  if core then
    return errors.new(core, props({ message = message, retry_after = retry_after }))
  end
  if status == 402 then
    return errors.new(PaymentRequired, props({ message = parsed and parsed.error_message }))
  end
  if status >= 500 then
    return errors.new(
      "InternalServerError",
      props({
        message = (message ~= "" and message) or ("HTTP " .. tostring(status)),
        retry_after = retry_after,
      })
    )
  end
  return errors.new(UnknownCoinbaseError, props({ message = parsed and parsed.error_message }))
end

return glue
