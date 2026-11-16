local t = require("spec.harness")
local distilled = require("distilled")
local json = require("distilled.json")
local errors = require("distilled.errors")
local secret = require("distilled.secret")

t.describe("distilled (init)", function()
  t.it("exposes null, secret and scope", function()
    t.eq(distilled.null, json.null)
    t.eq(distilled.secret, secret)
    t.eq(secret.unwrap(distilled.secret("k")), "k")
    t.eq(
      distilled.scope(function()
        return 5
      end),
      5
    )
  end)

  t.it("check returns the value", function()
    t.eq(distilled.check(42), 42)
    t.eq(distilled.check("x", nil), "x")
    local tbl = {}
    t.eq(distilled.check(tbl), tbl)
    t.eq(distilled.check(false), false)
  end)

  t.it("check raises tostring(err) as a string", function()
    local err = errors.new("NotFound", { message = "no project p1" })
    local ok, raised = t.pcall(function()
      return distilled.check(nil, err)
    end)
    t.eq(ok, false)
    t.eq(type(raised), "string")
    t.match(raised, "NotFound: no project p1", true)
  end)

  t.it("check works directly on a call's results", function()
    local function failing()
      return nil, errors.new("TooManyRequests", { message = "slow down" })
    end
    local raised = t.raises(function()
      distilled.check(failing())
    end)
    t.eq(type(raised), "string")
    t.match(raised, "TooManyRequests: slow down", true)
  end)

  t.it("check raises for a string error and for no error", function()
    t.raises(function()
      distilled.check(nil, "plain failure")
    end, "plain failure")
    t.raises(function()
      distilled.check(nil)
    end, "no value and no error")
  end)

  t.it("check raises the plain message, with no file:line prefix (level 0)", function()
    -- Rex shows the raised string as the action's failure: a position would point into
    -- the library and is noise there.
    local err = errors.new("NotFound", { message = "project not found" })
    local ok, raised = t.pcall(function()
      distilled.check(nil, err)
    end)
    t.eq(ok, false)
    t.eq(raised, "NotFound: project not found")
    ok, raised = t.pcall(function()
      distilled.check(nil, "where")
    end)
    t.eq(raised, "where")
    err.trace_id = "0123456789abcdef0123456789abcdef"
    ok, raised = t.pcall(function()
      distilled.check(nil, err)
    end)
    t.eq(raised, tostring(err))
    t.no_match(raised, "%.lua:%d+:")
  end)
end)
