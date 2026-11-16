-- A canary script below the client: the key goes through a host transport inside traced
-- spans, on success, an error status, a timeout, a refused connection and a slow request
-- (the one `ps` must catch in flight). `verify/dl canary verify/lib/canary_transport.lua`.
-- The end-to-end version through the full client is verify/lib/canary_e2e.lua.
local canary = require("verify.lib.canary")
local secret = require("distilled.secret")
canary.check_env()

local host = canary.host()
local tracer = canary.tracer(host)
local key = secret.wrap(canary.key)

local function call(label, path, opts)
  opts = opts or {}
  local res, err = tracer:with("canary." .. label, {
    kind = "client",
    attributes = {
      ["url.path"] = string.match(path, "^[^?]*"), -- never the query: it may hold a key
      credential = key, -- a secret attribute: must appear as <redacted>
    },
  }, function(span)
    local r, e = host.transport({
      method = opts.method or "GET",
      url = (opts.base or canary.url) .. path,
      headers = { authorization = "Bearer " .. secret.unwrap(key) },
      body = opts.body,
      timeout = opts.timeout or 10,
    })
    if r then
      span:set("http.response.status_code", r.status)
    end
    return r, e
  end)
  canary.report(label, res and { status = res.status } or nil, err)
end

call("echo", "/_dl/echo", { method = "POST", body = "{}" })
call("status_401", "/_dl/status/401")
call("slow", canary.SLOW_PATH)
call("timeout", "/_dl/slow?delay=3", { timeout = 0.3 })
call("refused", "/x?api_key=" .. canary.key, { base = "http://127.0.0.1:1" })
call("bad_header", "/_dl/echo", { method = "GET" })
print("key wrapped: " .. tostring(key))
local ok, err = tracer:flush()
print("flush: " .. tostring(ok or err))
return "done"
