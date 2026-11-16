local t = require("spec.harness")
local compat = require("distilled.compat")

t.describe("compat", function()
  t.it("unpack spreads a list, with ranges", function()
    local a, b, c = compat.unpack({ 1, 2, 3 })
    t.same({ a, b, c }, { 1, 2, 3 })
    local x, y = compat.unpack({ 1, 2, 3 }, 2, 3)
    t.same({ x, y }, { 2, 3 })
  end)

  t.it("pack counts trailing nils", function()
    local p = compat.pack(1, nil, nil)
    t.eq(p.n, 3)
    t.eq(p[1], 1)
    t.eq(compat.pack().n, 0)
  end)

  t.it("load compiles a string chunk", function()
    local fn = compat.load("return 1 + 2", "=chunk")
    t.eq(fn(), 3)
    local bad, msg = compat.load("return +", "=bad")
    t.eq(bad, nil)
    t.match(msg, "bad")
    t.raises(function()
      compat.load(function() end)
    end, "must be a string")
  end)

  t.it("normalize_number keeps values and makes integral numbers print plainly", function()
    t.eq(compat.normalize_number(3), 3)
    t.eq(tostring(compat.normalize_number(3.0)), "3")
    t.eq(compat.normalize_number(2.5), 2.5)
    local z = 0
    t.eq(1 / compat.normalize_number(-(z * 1.0)), -1 / 0)
  end)

  t.it("pcall catches errors, passes arguments and returns every value", function()
    local ok, a, b = compat.pcall(function(x, y)
      return x + 1, y
    end, 1, nil)
    t.eq(ok, true)
    t.eq(a, 2)
    t.eq(b, nil)
    local raised = { tag = "T" }
    local ok2, got = compat.pcall(error, raised)
    t.eq(ok2, false)
    t.eq(got, raised)
  end)

  t.it(
    "pcall keeps earlier closures' upvalues live after a caught error (gopher-lua bug)",
    function()
      local n = 0
      local function bump()
        n = n + 1
      end
      bump()
      compat.pcall(function()
        error("x")
      end)
      bump()
      t.eq(n, 2)
    end
  )

  -- gopher-lua bug 2: a protected call that catches after another protected call has
  -- completed inside it breaks upvalues (xpcall too). Counters are plain locals on
  -- purpose: that is what the bug corrupts.
  t.it("nested: a catching pcall after an inner one completed keeps upvalues live", function()
    local n = 0
    local function bump()
      n = n + 1
    end
    local ok, raised = compat.pcall(function()
      compat.pcall(function() end) -- completes inside the outer call
      error("outer", 0)
    end)
    bump()
    t.eq(ok, false)
    t.eq(raised, "outer")
    t.eq(n, 1)
  end)

  t.it("nested: an inner catch re-raised and caught again keeps upvalues live", function()
    local n = 0
    local function bump()
      n = n + 1
    end
    compat.pcall(function()
      local _, e = compat.pcall(error, "inner", 0)
      error(e, 0)
    end)
    bump()
    t.eq(n, 1)
  end)

  t.it("three levels of nesting, catching at every level", function()
    local counts = {}
    local n0 = 0
    local function bump0()
      n0 = n0 + 1
    end
    local ok1, e1 = compat.pcall(function()
      local n1 = 0
      local function bump1()
        n1 = n1 + 1
      end
      local ok2, e2 = compat.pcall(function()
        local n2 = 0
        local function bump2()
          n2 = n2 + 1
        end
        compat.pcall(function() end) -- a completed call at the deepest level
        local ok3, e3 = compat.pcall(function()
          compat.pcall(function() end)
          error({ level = 3 })
        end)
        bump2()
        counts[3] = { ok3, e3.level, n2 }
        error(e3)
      end)
      bump1()
      counts[2] = { ok2, e2.level, n1 }
      error(e2)
    end)
    bump0()
    t.same(counts[3], { false, 3, 1 })
    t.same(counts[2], { false, 3, 1 })
    t.eq(ok1, false)
    t.eq(e1.level, 3)
    t.eq(n0, 1)
  end)

  t.it("a protected call inside a Scope finalizer, with raises on every path", function()
    local Scope = require("distilled.scope")
    local n = 0
    local function bump()
      n = n + 1
    end
    local seen = {}
    local ok, raised = compat.pcall(function()
      return Scope.with(function(scope)
        scope:defer(function(reason)
          compat.pcall(function() end)
          local fok, ferr = compat.pcall(error, "in finalizer", 0)
          seen[#seen + 1] = { reason, fok, ferr }
          error("finalizer raises too", 0)
        end)
        error("body", 0)
      end)
    end)
    bump()
    t.eq(ok, false)
    t.eq(raised, "body") -- fn's error wins over the finalizer's
    t.same(seen, { { "body", false, "in finalizer" } })
    t.eq(n, 1)
  end)

  t.it("harness t.pcall is compat.pcall-safe when nested", function()
    local n = 0
    local function bump()
      n = n + 1
    end
    t.pcall(function()
      t.pcall(function() end)
      error("x")
    end)
    bump()
    t.eq(n, 1)
  end)

  t.it("pcall accepts C functions and callable tables, and keeps trailing nils", function()
    local ok, e = compat.pcall(error, { id = 1 })
    t.eq(ok, false)
    t.eq(e.id, 1)
    local callable = setmetatable({}, {
      __call = function(_, x)
        return x * 2
      end,
    })
    t.same({ compat.pcall(callable, 4) }, { true, 8 })
    t.eq(
      select(
        "#",
        compat.pcall(function()
          return 1, nil, nil
        end)
      ),
      4
    )
    t.eq(select("#", compat.pcall(function() end)), 1)
    local ok2, msg = compat.pcall(function()
      local x = nil
      return x.field
    end)
    t.eq(ok2, false)
    t.match(msg, "compat_spec.lua:%d+:")
  end)

  t.it("is yield-transparent inside a coroutine, values flowing both ways", function()
    local co = coroutine.create(function(start)
      return compat.pcall(function(a)
        local b = coroutine.yield(a + 1)
        local c = coroutine.yield(b + 1)
        return c + 1
      end, start)
    end)
    t.same({ coroutine.resume(co, 1) }, { true, 2 })
    t.same({ coroutine.resume(co, 10) }, { true, 11 })
    t.same({ coroutine.resume(co, 100) }, { true, true, 101 })
    t.eq(coroutine.status(co), "dead")
  end)

  t.it("passes yields through three nested pcalls and catches a raise after a yield", function()
    local co = coroutine.create(function()
      return compat.pcall(compat.pcall, compat.pcall, function()
        local v = coroutine.yield("deep")
        error({ after = v })
      end)
    end)
    t.same({ coroutine.resume(co) }, { true, "deep" })
    local ok, ok1, ok2, ok3, e = coroutine.resume(co, 7)
    t.eq(ok, true)
    t.eq(ok1, true)
    t.eq(ok2, true)
    t.eq(ok3, false)
    t.eq(e.after, 7)
  end)

  t.it("a yield outside any coroutine is a caught error, as with pcall", function()
    local ok, msg = compat.pcall(coroutine.yield, 1)
    t.eq(ok, false)
    t.eq(msg, "attempt to yield from outside a coroutine")
    -- nested, the yield travels out to the outermost call, which reports it
    local ok2, msg2 = compat.pcall(compat.pcall, coroutine.yield, 1)
    t.eq(ok2, false)
    t.eq(msg2, "attempt to yield from outside a coroutine")
  end)

  t.it("Scope.with is yield-transparent and closes once at the end", function()
    local Scope = require("distilled.scope")
    local closed = { n = 0 }
    local co = coroutine.create(function()
      return Scope.with(function(scope)
        scope:defer(function()
          closed.n = closed.n + 1
        end)
        local v = coroutine.yield("paused")
        return v .. "!"
      end)
    end)
    t.same({ coroutine.resume(co) }, { true, "paused" })
    t.eq(closed.n, 0)
    t.same({ coroutine.resume(co, "done") }, { true, "done!" })
    t.eq(closed.n, 1)
  end)

  t.it("works when called from inside a coroutine with no yield", function()
    local co = coroutine.wrap(function()
      local ok, e = compat.pcall(error, "x", 0)
      return ok, e, compat.pcall(function()
        return "fine"
      end)
    end)
    t.same({ co() }, { false, "x", true, "fine" })
  end)

  t.it("raise reports the caller's line at level 2, on every runtime", function()
    local function misuse()
      compat.raise("bad argument", 2)
    end
    local ok, message = compat.pcall(function()
      local line = debug.getinfo(1, "l").currentline
      misuse()
      return line
    end)
    t.eq(ok, false)
    t.match(message, "compat_spec.lua:%d+: bad argument")
    local ok0, plain = compat.pcall(compat.raise, "no position", 0)
    t.eq(ok0, false)
    t.eq(plain, "no position")
  end)

  t.it("concat joins any number of pieces (gopher-lua limit is ~2,500)", function()
    local parts = {}
    for i = 1, 12345 do
      parts[i] = "x"
    end
    local s = compat.concat(parts)
    t.eq(#s, 12345)
    t.eq(compat.concat({ "a", "b" }, ","), "a,b")
    local many = {}
    for i = 1, 1001 do
      many[i] = "y"
    end
    t.eq(#compat.concat(many, ","), 1001 + 1000)
    t.eq(compat.concat({}), "")
  end)
end)
