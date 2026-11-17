-- Cloudflare conformance in the test suite (task 19): replays the saved cases
-- (verify/conform/cloudflare/cases.jsonl, a sample of every model: requests, envelope
-- success and errors, pagination flows) through the generated clients/cloudflare under
-- this runtime and compares with Distilled's TS answers (ref.jsonl, from ts.mjs).
-- Zero mismatches beyond the intended differences (intended.lua); and a changed
-- reference must be reported, so a green run means something.
local t = require("spec.harness")

package.path = t.root
  .. "/clients/?.lua;"
  .. t.root
  .. "/clients/?/init.lua;"
  .. t.root
  .. "/?.lua;"
  .. package.path

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

local function first(report)
  local out = {}
  for i, m in ipairs(report.mismatches) do
    if i > 3 then
      break
    end
    out[#out + 1] = m.id .. "\n  lua " .. m.lua .. "\n  ts  " .. m.ts
  end
  return table.concat(out, "\n")
end

t.describe("cloudflare conform (vs Distilled TS)", function()
  local dir = t.root .. "/verify/conform/cloudflare/"
  if not (exists(dir .. "cases.jsonl") and exists(dir .. "ref.jsonl")) then
    t.pending("no saved cases/ref in verify/conform/cloudflare (see cases.lua, ts.mjs)")
    return
  end
  local compare = require("verify.conform.cloudflare.compare")
  local report

  t.it("every case is compared and none mismatches", function()
    report = compare.run(t.root)
    t.truthy(report.cases > 2000, "cases")
    t.eq(report.compared, report.cases)
    t.truthy((report.by_kind.request or 0) > 500, "requests")
    t.truthy((report.by_kind.response or 0) > 2000, "responses")
    t.truthy((report.by_kind.flow or 0) > 100, "pagination flows")
    t.eq(#report.mismatches, 0, first(report))
  end)

  t.it("a changed reference is reported as a mismatch", function()
    local changed = {
      ["d1.list_databases#flow"] = function(r)
        r.urls[2] = nil -- one page instead of two
      end,
      ["kv.list_namespaces#request"] = function(r)
        r.headers.authorization = "Bearer other"
      end,
      ["dns.list_records#typed-Forbidden"] = function(r)
        r.outcome.error.tag = "NotFound"
      end,
      ["dns.update_record#success"] = function(r)
        r.outcome.value.name = "other"
      end,
    }
    local seen = 0
    local r2 = compare.run(t.root, {
      patch_ref = function(r)
        if changed[r.id] then
          seen = seen + 1
          changed[r.id](r)
        end
      end,
    })
    t.eq(seen, 4, "patched references")
    local ids = {}
    for _, m in ipairs(r2.mismatches) do
      ids[m.id] = true
    end
    for id in pairs(changed) do
      t.truthy(ids[id], id .. " changed but not reported")
    end
    t.eq(#r2.mismatches, 4)
  end)
end)
