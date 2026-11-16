-- Intended differences between the Lua runtime and Distilled, each with its reason.
-- Every entry here is listed in verify/features/conformance.md. A diff matched by an
-- entry is reported as intended, not as a mismatch.
local intended = {}

-- { category, path = "<diff path pattern>", when = fn(case, d) -> bool | nil, reason }
intended.rules = {
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

local lib = require("verify.conform.lib")

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
        rule.category == category
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
