-- dl conform in the test suite: replays Distilled's saved reference dumps
-- (verify/conform/ref/neon) through the generated Neon client under this runtime, and
-- requires zero mismatches beyond the recorded intended differences. Also checks that
-- the comparison notices a changed reference (so a green run means something).
local t = require("spec.harness")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local context = require("verify.conform.context")
local lib = require("verify.conform.lib")

local function have_refs()
  return lib.read(t.root .. "/verify/conform/ref/neon/requests.jsonl") ~= nil
end

local function first_mismatches(tally)
  local out = {}
  for _, r in ipairs(tally.results) do
    if r.real and #r.real > 0 and #out < 5 then
      out[#out + 1] = r.id .. " " .. r.real[1].path
    end
  end
  return table.concat(out, "; ")
end

t.describe("conform replay (neon)", function()
  if not have_refs() then
    t.pending("no saved reference dumps in verify/conform/ref/neon (run verify/dl conform neon)")
    return
  end
  local ctx = context.new(t.root, "neon")

  for _, category in ipairs(context.CATEGORIES) do
    t.it(category .. ": no mismatch against Distilled", function()
      local tally = context.tally(ctx, category)
      t.truthy(tally.n > 0, "cases")
      t.eq(tally.mismatched, 0, first_mismatches(tally))
      t.eq(tally.ok + tally.skipped, tally.n)
    end)
  end

  t.it("a changed reference is reported as a mismatch", function()
    local check = require("verify.conform.check_responses")
    local real_read = lib.read_lines
    lib.read_lines = function(path)
      local list = real_read(path)
      if string.find(path, "ref/neon/responses.jsonl", 1, true) then
        for _, r in ipairs(list) do
          if r.id == "get_project/404" then
            r.error.tag = "Gone"
          elseif r.id == "create_api_key/secret-key" then
            r.value.key = "napi_secret" -- Distilled redacted it; plain would be a leak
          end
        end
      end
      return list
    end
    local results = check.run(ctx)
    lib.read_lines = real_read
    local seen = {}
    for _, r in ipairs(results) do
      if
        #(r.diffs or {}) > 0 and (r.id == "get_project/404" or r.id == "create_api_key/secret-key")
      then
        local real = require("verify.conform.intended").split("responses", r)
        seen[r.id] = #real
      end
    end
    t.eq(seen["get_project/404"], 1)
    t.eq(seen["create_api_key/secret-key"], 1)
  end)
end)
