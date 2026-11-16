-- The context every conform check runs with, and one category's tally. Used by
-- compare.lua (dl conform) and spec/conform_replay_spec.lua.
local intended = require("verify.conform.intended")

local context = {}

context.CATEGORIES = { "members", "requests", "responses", "flows" }

--- context.new(root, provider) -> ctx (the generated client must be on package.path)
function context.new(root, provider)
  return {
    root = root,
    provider = provider,
    cases_dir = root .. "/verify/conform/cases/" .. provider,
    ref_dir = root .. "/verify/conform/ref/" .. provider,
    class = require(provider),
    service = require(provider .. ".service"),
    skip = intended.skip,
  }
end

--- context.tally(ctx, category) -> { n, ok, mismatched, skipped, intended, results }
-- each result gains .real (diffs that are mismatches) and .known (intended diffs)
function context.tally(ctx, category)
  local check = require("verify.conform.check_" .. category)
  local results = check.run(ctx)
  local t = { n = #results, ok = 0, mismatched = 0, skipped = 0, intended = 0, results = results }
  for _, r in ipairs(results) do
    if r.skipped then
      t.skipped = t.skipped + 1
    else
      r.real, r.known = intended.split(category, r)
      if #r.known > 0 then
        t.intended = t.intended + 1
      end
      if #r.real == 0 then
        t.ok = t.ok + 1
      else
        t.mismatched = t.mismatched + 1
      end
    end
  end
  return t
end

return context
