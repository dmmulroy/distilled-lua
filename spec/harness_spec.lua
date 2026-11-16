-- The harness checks itself: each assertion must fail when it should, with a message
-- that names what differed.
local t = require("spec.harness")

local function failure_of(fn)
  local ok, raised = t.pcall(fn)
  if ok then
    t.fail("expected the assertion to fail")
  end
  if not t.is_failure(raised) then
    t.fail("expected a harness failure, got " .. t.show(raised))
  end
  return raised
end

t.describe("harness assertions", function()
  t.it("eq fails with expected and actual", function()
    local f = failure_of(function()
      t.eq(1, 2)
    end)
    t.match(f.message, "expected: 2", true)
    t.match(f.message, "actual:   1", true)
    t.match(f.where, "harness_spec.lua:%d+")
  end)

  t.it("same names the first differing path", function()
    local f = failure_of(function()
      t.same({ a = { b = { 1, 2 } } }, { a = { b = { 1, 3 } } })
    end)
    t.match(f.message, "differ at value.a.b[2]", true)
    t.match(f.message, "expected: 3", true)
    t.match(f.message, "actual:   2", true)
  end)

  t.it("same notices missing and extra keys", function()
    t.match(
      failure_of(function()
        t.same({ a = 1 }, { a = 1, b = 2 })
      end).message,
      "value.b",
      true
    )
    t.match(
      failure_of(function()
        t.same({ a = 1, c = 3 }, { a = 1 })
      end).message,
      "value.c",
      true
    )
  end)

  t.it("same passes for equal tables, ignoring metatables", function()
    t.same(setmetatable({ 1, { x = "y" } }, {}), { 1, { x = "y" } })
    t.same(0 / 0, 0 / 0)
  end)

  t.it("truthy, falsy, match, no_match, raises fail when they should", function()
    failure_of(function()
      t.truthy(nil)
    end)
    failure_of(function()
      t.falsy(1)
    end)
    failure_of(function()
      t.match("abc", "^b")
    end)
    failure_of(function()
      t.no_match("abc", "b")
    end)
    failure_of(function()
      t.raises(function() end)
    end)
    failure_of(function()
      t.raises(function()
        error("x")
      end, "nomatch")
    end)
  end)

  t.it("err checks nil, an error table and the tag", function()
    local e = { tag = "NotFound", message = "m" }
    t.eq(t.err(nil, e, "NotFound"), e)
    t.match(
      failure_of(function()
        t.err(1, nil)
      end).message,
      "expected nil, err",
      true
    )
    t.match(
      failure_of(function()
        t.err(nil, "string")
      end).message,
      "error table",
      true
    )
    t.match(
      failure_of(function()
        t.err(nil, e, "Conflict")
      end).message,
      "expected error tag",
      true
    )
    t.eq(t.fails_with("NotFound", nil, e), e)
  end)

  t.it("show renders nested values with sorted keys", function()
    t.eq(t.show({ b = 1, a = "x", 10 }), '{ 10, a = "x", b = 1 }')
    local cyc = {}
    cyc.me = cyc
    t.match(t.show(cyc), "<cycle>", true)
  end)

  t.it("_run reports raised non-assertion errors with a traceback", function()
    local failure = t._run({
      fn = function()
        error("kaboom")
      end,
    })
    t.match(failure.message, "raised: ", true)
    t.match(failure.message, "kaboom", true)
    t.eq(t._run({ fn = function() end }), nil)
  end)
end)
