-- Intended differences between the Lua runtime and Distilled, each with its reason.
local json = require("distilled.json")
local lib = require("verify.conform.lib")

-- Every entry here is listed in verify/features/conformance.md. A diff matched by an
-- entry is reported as intended, not as a mismatch.
local intended = {}

-- { category, path = "<diff path pattern>", when = fn(case, d) -> bool | nil, reason }
-- The response a result's error came from (responses: the case's; flows: the last one).
local function last_response(case)
  if case.response then
    return case.response
  end
  local script = case.script or {}
  return script[#script]
end

local function wire_code(case)
  local r = last_response(case)
  if type(r) ~= "table" or type(r.body) ~= "string" then
    return nil
  end
  local body = json.decode(r.body)
  if type(body) == "table" and body ~= json.null then
    return body.code
  end
  return nil
end

local OUTCOME = { responses = true, flows = true }

intended.rules = {
  {
    category = OUTCOME,
    path = "^%.error%.status$",
    when = function(case, d)
      local r = last_response(case)
      return d.a == nil and type(r) == "table" and d.b == (r.status or 200)
    end,
    reason = "every Lua HTTP error carries `status`; Distilled's typed and status-mapped "
      .. "classes (BadRequest, NotFound, ServiceUnavailable, ...) have no status field",
  },
  {
    category = OUTCOME,
    path = "^%.error%.code$",
    when = function(case, d)
      local wire = wire_code(case)
      if d.a == 0 then
        -- Distilled's generated classes declare `code: S.Number`: a string or absent wire
        -- code becomes 0; Lua keeps the wire code or nil
        return d.b == nil or d.b == wire
      end
      -- Distilled's built-in status classes have no code field; Lua keeps the wire code
      return d.a == nil and d.b ~= nil and d.b == wire
    end,
    reason = "`code` is the wire code or nil in Lua; Distilled has 0 on generated classes "
      .. "(a Number field) and no code on its built-in status classes",
  },
  {
    category = OUTCOME,
    path = "^%.error%.message$",
    when = function(_, d, result)
      local got = result.got
      return d.a == ""
        and got
        and got.error
        and string.find(tostring(got.error.tag), "ParseError$") ~= nil
    end,
    reason = "a Lua parse error says what failed (the decode or validation mismatch and its "
      .. "path); Distilled's <Sdk>ParseError has an empty message and keeps the detail in `cause`",
  },
  {
    category = OUTCOME,
    path = "^%.error%.retry_after$",
    when = function(case, d)
      local r = last_response(case)
      local ra = type(r) == "table" and r.headers and r.headers["retry-after"]
      -- asctime has no zone: RFC 9110 says GMT; JavaScript's Date.parse reads it in the
      -- host's local zone, so Distilled is off by the machine's UTC offset
      return type(ra) == "string"
        and string.find(ra, "^%a%a%a %a%a%a +%d+ %d%d:%d%d:%d%d %d%d%d%d$") ~= nil
    end,
    reason = "an asctime Retry-After is read as GMT (RFC 9110 5.6.7); Distilled's Date.parse "
      .. "reads it in the local time zone, so its value depends on the machine",
  },
  {
    category = "requests",
    path = "^outcome$",
    when = function(case, d)
      return d.a == "request"
        and string.find(
            tostring(d.b),
            "^error InvalidInput: Input member [%w_]+ is required: it fills the path"
          )
          ~= nil
    end,
    reason = "a missing path label is InvalidInput in Lua; Distilled sends the literal {name} "
      .. "in the path (protocol-http.ts buildRequest leaves the placeholder)",
  },
}

-- Cases not compared at all: fn(case, ctx) -> reason | nil
function intended.skip(case, ctx)
  local op = ctx.service.ops[case.op]
  if
    op
    and op.content_type == "multipart"
    and not lib.read(ctx.root .. "/tasks/08-multipart.done.md")
  then
    return "multipart: task 08 is still running (tasks/08-multipart.done.md is absent)"
  end
  return nil
end

--- split(category, result) -> real diffs, intended diffs (each with .reason)
function intended.split(category, result)
  local real, known = {}, {}
  for _, d in ipairs(result.diffs or {}) do
    local reason
    for _, rule in ipairs(intended.rules) do
      if
        (rule.category == category or (type(rule.category) == "table" and rule.category[category]))
        and string.find(d.path, rule.path)
        and (rule.when == nil or rule.when(result.case, d, result))
      then
        reason = rule.reason
        break
      end
    end
    if reason then
      d.reason = reason
      known[#known + 1] = d
    else
      real[#real + 1] = d
    end
  end
  return real, known
end

return intended
