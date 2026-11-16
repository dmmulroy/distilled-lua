local t = require("spec.harness")
local secret = require("distilled.secret")
local json = require("distilled.json")

local CANARY = "sk-CANARY-9f8e7d"

t.describe("secret", function()
  t.it("prints as <redacted>", function()
    local s = secret.wrap(CANARY)
    t.eq(tostring(s), "<redacted>")
    t.eq(string.format("%s", tostring(s)), "<redacted>")
  end)

  t.it("does not leak through concatenation", function()
    local s = secret.wrap(CANARY)
    t.eq("key=" .. s, "key=<redacted>")
    t.eq(s .. "!", "<redacted>!")
  end)

  t.it("does not leak through pairs or a table dump", function()
    local s = secret.wrap(CANARY)
    t.eq(next(s), nil)
    t.no_match(t.show(s), "CANARY", true)
    t.no_match(t.show({ token = s }), "CANARY", true)
  end)

  t.it("unwraps explicitly; unwrap of a plain value returns it", function()
    t.eq(secret.unwrap(secret.wrap(CANARY)), CANARY)
    t.eq(secret.unwrap("plain"), "plain")
    t.eq(secret.unwrap(nil), nil)
  end)

  t.it("wrapping a secret returns the same secret", function()
    local s = secret.wrap(CANARY)
    t.eq(secret.wrap(s), s)
  end)

  t.it("is() tells secrets from plain values", function()
    t.truthy(secret.is(secret.wrap("x")))
    t.falsy(secret.is("x"))
    t.falsy(secret.is({}))
    t.falsy(secret.is(nil))
    t.falsy(secret.is(setmetatable({}, {
      __tostring = function()
        return "<redacted>"
      end,
    })))
  end)

  t.it("wraps non-string values too", function()
    local s = secret.wrap({ user = "u", pass = CANARY })
    t.eq(secret.unwrap(s).pass, CANARY)
    t.eq(secret.unwrap(secret.wrap(false)), false)
  end)

  t.it("is read-only", function()
    local s = secret.wrap(CANARY)
    t.raises(function()
      s.x = 1
    end, "read%-only")
  end)

  t.it("is callable as secret(value)", function()
    t.eq(secret.unwrap(secret("v")), "v")
  end)

  t.it("json.encode refuses it without leaking", function()
    local out, err = json.encode({ k = secret.wrap(CANARY) })
    t.eq(out, nil)
    t.no_match(tostring(err), "CANARY", true)
  end)
end)

t.describe("secret.unwrap_deep", function()
  t.it("unwraps every secret in nested tables and arrays, without changing the input", function()
    local input = {
      token = secret.wrap("t1"),
      list = json.array({ secret.wrap("a"), "b", { inner = secret.wrap("c") } }),
      plain = 1,
    }
    local out = secret.unwrap_deep(input)
    t.same(out, { token = "t1", list = { "a", "b", { inner = "c" } }, plain = 1 })
    t.truthy(json.is_array(out.list), "array mark kept")
    t.truthy(secret.is(input.token), "input untouched")
    t.truthy(secret.is(input.list[3].inner), "input untouched")
    t.ne(out, input)
  end)

  t.it("returns scalars and unwraps a top-level secret", function()
    t.eq(secret.unwrap_deep("x"), "x")
    t.eq(secret.unwrap_deep(secret.wrap("y")), "y")
    t.eq(secret.unwrap_deep(nil), nil)
  end)

  t.it("copies shared and cyclic tables once", function()
    local shared = { s = secret.wrap("z") }
    local root = { a = shared, b = shared }
    root.self = root
    local out = secret.unwrap_deep(root)
    t.eq(out.a, out.b)
    t.eq(out.self, out)
    t.eq(out.a.s, "z")
  end)

  t.it("handles deep nesting without recursion", function()
    local root = {}
    local cur = root
    for _ = 1, 2000 do
      cur.next = {}
      cur = cur.next
    end
    cur.key = secret.wrap("deep")
    local out = secret.unwrap_deep(root)
    for _ = 1, 2000 do
      out = out.next
    end
    t.eq(out.key, "deep")
  end)
end)
