local t = require("spec.harness")
local validate = require("distilled.validate")
local S = require("distilled.schema")
local json = require("distilled.json")

local m = S.member

local function struct(members, open)
  return S.struct({ members = members, open = open })
end

local ITEMS = struct({
  m({
    name = "items",
    schema = S.list(struct({ m({ name = "id", schema = S.string, required = true }) })),
    required = true,
  }),
})

local function ok(node, value, opts, registry)
  return validate.check(node, value, registry, opts) == true
end

-- Distilled response-validation-strict.test.ts
t.describe("validate: strict checker (response-validation-strict.test.ts)", function()
  t.it("exact mode: unmodeled keys fail at their path; open structs and {} accept them", function()
    local r, mm = validate.check(
      ITEMS,
      json.decode('{"items":[{"id":"a"},{"id":"b","extra":1}]}'),
      nil,
      { exact = true }
    )
    t.eq(r, nil)
    t.same(mm.path, { "items", 2, "extra" })
    t.eq(mm.expected, "no value (the schema does not model this key)")
    t.eq(mm.actual, 1)
    t.truthy(ok(ITEMS, json.decode('{"items":[]}'), { exact = true }))
    t.truthy(ok(struct({}), { anything = 1 }, { exact = true }))
    local open = struct({ m({ name = "id", schema = S.string, required = true }) }, true)
    t.truthy(ok(open, { id = "a", title = "x" }, { exact = true }))
  end)

  t.it("reports the path and the expected type", function()
    local r, mm = validate.check(ITEMS, json.decode('{"items":[{"id":"a"},{"id":4}]}'))
    t.eq(r, nil)
    t.same(mm.path, { "items", 2, "id" })
    t.eq(mm.expected, "string")
    t.eq(mm.message, 'Expected string, got 4 at ["items",2,"id"]')
    t.truthy(ok(ITEMS, { items = {} }))
  end)

  t.it("open structs keep declared checks and accept any extra key", function()
    local row = struct({
      m({ name = "id", schema = S.string, required = true }),
      m({ name = "vector", schema = S.list(S.number) }),
    }, true)
    for _, exact in ipairs({ false, true }) do
      local o = { exact = exact }
      t.truthy(
        ok(row, { id = "a", title = "x", ["$dist"] = 0.1, tags = { "t" }, n = json.null }, o)
      )
      t.truthy(ok(row, { id = "a", vector = { 1 } }, o))
      t.falsy(ok(row, { title = "x" }, o))
      t.falsy(ok(row, { id = 1, title = "x" }, o))
      t.falsy(ok(row, { id = "a", vector = "nope" }, o))
    end
  end)

  t.it("a map checks every value", function()
    local node = struct({
      m({ name = "id", schema = S.string }),
      m({ name = "labels", schema = S.map(S.list(S.unknown)) }),
    })
    t.truthy(ok(node, { id = "a", labels = { title = { 1 } } }))
    local r, mm = validate.check(node, { id = "a", labels = { title = "x" } })
    t.eq(r, nil)
    t.same(mm.path, { "labels", "title" })
    t.eq(mm.expected, "array")
  end)

  t.it("recursive schemas", function()
    local reg = {
      Tree = struct({
        m({ name = "v", schema = S.number, required = true }),
        m({ name = "kids", schema = S.list(S.ref("Tree")) }),
      }),
    }
    local tree = S.ref("Tree")
    t.truthy(ok(tree, { v = 1 }, nil, reg))
    t.truthy(ok(tree, { v = 1, kids = { { v = 2, kids = {} } } }, nil, reg))
    t.falsy(ok(tree, { v = 1, kids = { { v = "2" } } }, nil, reg))
    t.falsy(ok(tree, { v = 1, kids = { { kids = {} } } }, nil, reg))
  end)

  t.it("deep recursive values are checked without recursion", function()
    local reg = {
      N = struct({
        m({ name = "next", schema = S.ref("N") }),
        m({ name = "v", schema = S.number, required = true }),
      }),
    }
    local root = { v = 0 }
    local cur = root
    for i = 1, 700 do
      cur.next = { v = i }
      cur = cur.next
    end
    t.truthy(ok(S.ref("N"), root, nil, reg))
    cur.v = "bad"
    local r, mm = validate.check(S.ref("N"), root, reg)
    t.eq(r, nil)
    t.eq(#mm.path, 701)
  end)
end)

-- Distilled response-validation.test.ts (the checker's part of it)
t.describe("validate: modes (response-validation.test.ts)", function()
  local OUT = struct({ m({ name = "id", schema = S.string, required = true }) })

  t.it("additional (exact = false) passes a matching body, extra members included", function()
    t.truthy(ok(OUT, { id = "a", extra = 1 }))
  end)

  t.it("both modes fail a body missing a required member", function()
    for _, exact in ipairs({ false, true }) do
      local r, mm = validate.check(OUT, json.decode("{}"), nil, { exact = exact })
      t.eq(r, nil)
      t.same(mm.path, { "id" })
      t.eq(mm.expected, "a value")
      t.eq(mm.missing, true)
      t.eq(mm.message, 'Expected a value, got nothing (missing key) at ["id"]')
    end
  end)

  t.it("strict fails a member the schema does not model, at its path", function()
    local r, mm = validate.check(OUT, { id = "a", extra = 1 }, nil, { exact = true })
    t.eq(r, nil)
    t.same(mm.path, { "extra" })
    t.eq(mm.expected, "no value (the schema does not model this key)")
  end)

  t.it("strict passes a body with exactly the modeled members", function()
    t.truthy(ok(OUT, { id = "a" }, { exact = true }))
  end)
end)

t.describe("validate: rules", function()
  t.it("json.null satisfies only nullable (or null/unknown) members", function()
    local node = struct({
      m({ name = "a", schema = S.string, nullable = true }),
      m({ name = "b", schema = S.string }),
      m({ name = "c", schema = S.unknown }),
      m({ name = "d", schema = S.null }),
    })
    t.truthy(ok(node, { a = json.null, c = json.null, d = json.null }))
    local r, mm = validate.check(node, { b = json.null })
    t.eq(r, nil)
    t.same(mm.path, { "b" })
    t.eq(mm.expected, "string")
    t.eq(mm.actual, json.null)
    t.eq(mm.message, 'Expected string, got null at ["b"]')
  end)

  t.it("a null in a list is checked against the item type", function()
    t.falsy(ok(S.list(S.string), json.decode('["a",null]')))
    t.truthy(ok(S.list(S.unknown), json.decode('["a",null]')))
  end)

  t.it("an empty struct accepts any value but null", function()
    t.truthy(ok(struct({}), "text"))
    t.truthy(ok(struct({}), json.array({})))
    t.falsy(ok(struct({}), json.null))
    t.falsy(ok(struct({}), nil))
  end)

  t.it("scalars", function()
    t.truthy(ok(S.number, 1.5))
    t.falsy(ok(S.number, "1"))
    t.truthy(ok(S.boolean, false))
    t.falsy(ok(S.boolean, 0))
    t.truthy(ok(S.blob, "\0\1"))
    t.truthy(ok(S.timestamp, "2024-01-01T00:00:00Z"))
    t.truthy(ok(S.timestamp, 1700000000))
    t.falsy(ok(S.timestamp, true))
    t.truthy(ok(S.unknown, { any = "thing" }))
    t.truthy(ok(S.null, json.null))
    t.falsy(ok(S.null, "null"))
  end)

  t.it("enums are open unless exact", function()
    local e = S.enum({ "admin", "member" })
    t.truthy(ok(e, "owner"))
    t.falsy(ok(e, "owner", { exact = true }))
    t.truthy(ok(e, "admin", { exact = true }))
    t.falsy(ok(e, 1))
    t.truthy(ok(S.enum({ 1, 2 }, "number"), 3))
  end)

  t.it("a list needs an array, a struct an object", function()
    t.falsy(ok(S.list(S.string), json.decode('{"a":1}')))
    t.truthy(ok(S.list(S.string), {}))
    local r, mm = validate.check(ITEMS, json.decode("[]"))
    t.eq(r, nil)
    t.eq(mm.expected, "object")
    t.eq(mm.message, "Expected object, got an array")
  end)

  t.it("unions: any arm; one arm reports its own failure", function()
    local a = struct({ m({ name = "a", schema = S.string, required = true }) })
    local b = struct({ m({ name = "b", schema = S.number, required = true }) })
    t.truthy(ok(S.union({ a, b }), { b = 1 }))
    local r, mm = validate.check(S.union({ a, b }), { c = 1 })
    t.eq(r, nil)
    t.eq(mm.expected, "a union member")
    local r1, m1 =
      validate.check(struct({ m({ name = "x", schema = S.union({ a }) }) }), { x = { a = 5 } })
    t.eq(r1, nil)
    t.same(m1.path, { "x", "a" })
    t.eq(m1.expected, "string")
  end)

  t.it("the first mismatch follows declaration order", function()
    local node = struct({
      m({ name = "z", schema = S.string, required = true }),
      m({ name = "a", schema = S.string, required = true }),
    })
    local _, mm = validate.check(node, { a = 1 })
    t.same(mm.path, { "z" })
    local _, m2 = validate.check(node, { z = 1, a = 1 })
    t.same(m2.path, { "z" })
  end)

  t.it("a missing ref is a mismatch, not a raise", function()
    local r, mm = validate.check(S.ref("Missing"), {}, {})
    t.eq(r, nil)
    t.match(mm.expected, "Missing", true)
  end)

  t.it("withhold replaces the value found", function()
    local _, mm = validate.check(S.number, "s3cret-CANARY")
    t.match(mm.message, "CANARY", true)
    local w = validate.withhold(mm)
    t.eq(w.actual, "[REDACTED]")
    t.no_match(w.message, "CANARY", true)
    t.eq(w.expected, "number")
  end)

  t.it("long strings are cut in the message", function()
    local _, mm = validate.check(S.number, string.rep("x", 100))
    t.match(mm.message, "...", true)
    t.truthy(#mm.message < 80)
  end)

  t.it("the fixture service bodies validate in strict mode", function()
    local fixtures = require("distilled.testing.fixtures")
    local s = fixtures.service()
    local body = json.decode(json.encode(fixtures.bodies.project("p1")))
    t.truthy(ok(s.ops.get_project.output, body, { exact = true }, s.shapes))
    local page = json.decode(json.encode(fixtures.bodies.page({ "a", "b" }, "c")))
    t.truthy(ok(s.ops.list_projects.output, page, { exact = true }, s.shapes))
    body.project.surprise = true
    local r, mm = validate.check(s.ops.get_project.output, body, s.shapes, { exact = true })
    t.eq(r, nil)
    t.same(mm.path, { "project", "surprise" })
  end)
end)
