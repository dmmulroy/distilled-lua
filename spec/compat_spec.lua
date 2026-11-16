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
