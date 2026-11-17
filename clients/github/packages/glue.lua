-- GitHub's rate-limit reading (packages/github/src/protocol.ts rateLimited): a 403 or
-- 429 with Retry-After, x-ratelimit-remaining: 0 or "rate limit" in the message is
-- TooManyRequests; the wait is Retry-After, else until x-ratelimit-reset when the quota
-- is exhausted, else a minute (the secondary rate limit).
local errors = require("distilled.errors")
local retry = require("distilled.retry")

local SECONDARY_RATE_LIMIT_WAIT_S = 60

local glue = {}

function glue.classify_error(info)
  if info.status ~= 403 and info.status ~= 429 then
    return nil
  end
  local headers = info.headers or {}
  local retry_after = retry.parse_retry_after(headers, info.now)
  local exhausted = headers["x-ratelimit-remaining"] == "0"
  local message = type(info.message) == "string" and info.message or ""
  if
    retry_after == nil
    and not exhausted
    and not string.find(string.lower(message), "rate limit", 1, true)
  then
    return nil
  end
  local wait = retry_after
  if wait == nil then
    local reset = tonumber(headers["x-ratelimit-reset"] or "")
    if exhausted and reset then
      wait = math.max(0, reset - (info.now or os.time()))
    else
      wait = SECONDARY_RATE_LIMIT_WAIT_S
    end
  end
  return errors.new("TooManyRequests", {
    message = info.message,
    status = info.status,
    code = info.code,
    body = info.body,
    headers = info.headers,
    retry_after = wait,
  })
end

return glue
