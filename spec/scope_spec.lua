local t = require("spec.harness")
local Scope = require("distilled.scope")

t.describe("Scope", function()
  t.it("runs finalizers last-in first-out", function()
    local order = {}
    local scope = Scope.new()
    scope:defer(function()
      order[#order + 1] = 1
    end)
    scope:defer(function()
      order[#order + 1] = 2
    end)
    scope:defer(function()
      order[#order + 1] = 3
    end)
    t.eq(scope:close(), true)
    t.same(order, { 3, 2, 1 })
  end)

  t.it("defer returns nothing", function()
    local scope = Scope.new()
    t.eq(select("#", scope:defer(function() end)), 0)
  end)

  t.it("passes the close reason to each finalizer", function()
    local seen = {}
    local scope = Scope.new()
    scope:defer(function(err)
      seen[#seen + 1] = err == nil and "nil" or err
    end)
    scope:close("boom")
    local scope2 = Scope.new()
    scope2:defer(function(err)
      seen[#seen + 1] = err == nil and "nil" or err
    end)
    scope2:close()
    t.same(seen, { "boom", "nil" })
  end)

  t.it("runs every finalizer even when some raise, and returns what they raised", function()
    local ran = {}
    local scope = Scope.new()
    scope:defer(function()
      ran[#ran + 1] = "a"
    end)
    scope:defer(function()
      error("second failed", 0)
    end)
    scope:defer(function()
      ran[#ran + 1] = "c"
    end)
    scope:defer(function()
      error({ code = 7 })
    end)
    local ok, errs = scope:close()
    t.eq(ok, nil)
    t.same(ran, { "c", "a" })
    t.eq(#errs, 2)
    t.same(errs[1], { code = 7 })
    t.eq(errs[2], "second failed")
  end)

  t.it("close is idempotent", function()
    local n = 0
    local scope = Scope.new()
    scope:defer(function()
      n = n + 1
    end)
    scope:close()
    t.eq(scope:close(), true)
    t.eq(n, 1)
  end)

  t.it("defer on a closed scope runs the finalizer at once", function()
    local scope = Scope.new()
    scope:close()
    local ran = false
    scope:defer(function()
      ran = true
    end)
    t.truthy(ran)
  end)

  t.it("rejects a non-function finalizer", function()
    t.raises(function()
      Scope.new():defer("x")
    end, "expected a function")
  end)

  t.it("an empty scope closes cleanly", function()
    t.eq(Scope.new():close(), true)
  end)
end)

t.describe("Scope.with", function()
  t.it("returns every value fn returns, including nil, err pairs", function()
    local a, b, c = Scope.with(function()
      return 1, nil, 3
    end)
    t.eq(a, 1)
    t.eq(b, nil)
    t.eq(c, 3)
    local v, err = Scope.with(function()
      return nil, "failed"
    end)
    t.eq(v, nil)
    t.eq(err, "failed")
  end)

  t.it("closes the scope on return", function()
    local closed = false
    Scope.with(function(scope)
      scope:defer(function(err)
        closed = err == nil
      end)
    end)
    t.truthy(closed)
  end)

  t.it("closes on a raise and re-raises the original value", function()
    local reason
    local original = { tag = "Boom" }
    local ok, raised = t.pcall(function()
      return Scope.with(function(scope)
        scope:defer(function(err)
          reason = err
        end)
        error(original)
      end)
    end)
    t.eq(ok, false)
    t.eq(raised, original)
    t.eq(reason, original)
  end)

  t.it("re-raises a string without adding a second position", function()
    local ok, raised = t.pcall(function()
      return Scope.with(function()
        error("plain message", 0)
      end)
    end)
    t.eq(ok, false)
    t.eq(raised, "plain message")
  end)

  t.it("a failing finalizer does not replace fn's error or its results", function()
    local ok, raised = t.pcall(function()
      return Scope.with(function(scope)
        scope:defer(function()
          error("finalizer", 0)
        end)
        error("body", 0)
      end)
    end)
    t.eq(ok, false)
    t.eq(raised, "body")
    local v = Scope.with(function(scope)
      scope:defer(function()
        error("finalizer", 0)
      end)
      return "value"
    end)
    t.eq(v, "value")
  end)

  t.it("rejects a non-function", function()
    t.raises(function()
      Scope.with(nil)
    end, "expected a function")
  end)
end)
