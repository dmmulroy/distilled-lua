local t = require("spec.harness")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")

t.describe("schema: constructors", function()
  t.it("scalars are plain nodes", function()
    for _, name in ipairs({ "string", "number", "boolean", "null", "unknown", "blob", "timestamp" }) do
      t.same(S[name], { t = name })
    end
    t.same(S.scalar("string", { sensitive = true }), { t = "string", sensitive = true })
  end)

  t.it("sensitive copies, never changes the shared node", function()
    local n = S.sensitive(S.string)
    t.eq(n.sensitive, true)
    t.eq(S.string.sensitive, nil)
  end)

  t.it("containers, refs and unions match the contract", function()
    t.same(S.list(S.string), { t = "list", item = { t = "string" } })
    t.same(S.map(S.number), { t = "map", value = { t = "number" } })
    t.same(S.ref("X"), { t = "ref", name = "X" })
    t.same(S.enum({ "a" }), { t = "enum", values = { "a" }, base = "string" })
    local u = S.union({ S.string }, { key = "type", values = { "s" } })
    t.eq(u.t, "union")
    t.eq(u.discriminator.key, "type")
  end)

  t.it("member fills the contract defaults", function()
    t.same(S.member({ name = "id", schema = S.string }), {
      name = "id",
      bind = "body",
      schema = { t = "string" },
      required = false,
      nullable = false,
      sensitive = false,
      greedy = false,
      string_encoded = false,
    })
  end)

  t.it("struct keeps members in order and refuses duplicates", function()
    local st = S.struct({ name = "X", members = { S.member({ name = "a", schema = S.string }) } })
    t.eq(st.t, "struct")
    t.eq(st.open, false)
    t.eq(st.members[1].name, "a")
    t.raises(function()
      S.struct({
        members = {
          S.member({ name = "a", schema = S.string }),
          S.member({ name = "a", schema = S.string }),
        },
      })
    end, "twice")
  end)

  t.it("misuse raises with a clear message", function()
    t.raises(function()
      S.member({ name = "a", schema = S.string, bind = "cookie" })
    end, "unknown bind")
    t.raises(function()
      S.member({ name = "a", schema = S.string, style = "pipe" })
    end, "unknown query style")
    t.raises(function()
      S.member({ name = "a" })
    end, "needs a schema")
    t.raises(function()
      S.list()
    end, "item node")
    t.raises(function()
      S.union({})
    end, "non%-empty")
    t.raises(function()
      S.ref("")
    end, "shape name")
    t.raises(function()
      S.enum({ "a" }, "boolean")
    end, "enum base")
  end)
end)

t.describe("schema: resolve", function()
  t.it("follows refs and chains of refs", function()
    local target = S.struct({ members = {} })
    local reg = { A = S.ref("B"), B = target }
    t.eq(S.resolve(S.ref("A"), reg), target)
    t.eq(S.resolve(S.string, reg), S.string)
  end)

  t.it("a missing name fails with SdkError", function()
    local node, err = S.resolve(S.ref("Nope"), {})
    t.fails_with("SdkError", node, err)
    t.match(err.message, "Nope", true)
    t.fails_with("SdkError", S.resolve(S.ref("Nope"), nil))
  end)

  t.it("a ref cycle fails instead of looping", function()
    local node, err = S.resolve(S.ref("A"), { A = S.ref("B"), B = S.ref("A") })
    t.fails_with("SdkError", node, err)
    t.match(err.message, "too long", true)
  end)

  t.it("node_sensitive reads through refs", function()
    t.truthy(S.node_sensitive(S.ref("T"), { T = S.sensitive(S.string) }))
    t.falsy(S.node_sensitive(S.ref("T"), { T = S.string }))
    t.falsy(S.node_sensitive(S.ref("T"), {}))
  end)
end)

t.describe("schema: plan", function()
  local node = S.struct({
    members = {
      S.member({ name = "id", bind = "label", schema = S.string }),
      S.member({ name = "limit", bind = "query", schema = S.number }),
      S.member({ name = "trace", wire = "X-Trace", bind = "header", schema = S.string }),
      S.member({ name = "displayName", wire = "display_name", schema = S.string }),
      S.member({ name = "raw", bind = "payload", schema = S.blob }),
    },
  })

  t.it("groups members by binding, in declaration order", function()
    local plan = S.plan(node)
    t.eq(#plan.by_bind.label, 1)
    t.eq(plan.by_bind.query[1].name, "limit")
    t.eq(plan.by_bind.header[1].name, "trace")
    t.eq(plan.by_bind.body[1].name, "displayName")
    t.eq(plan.payload.name, "raw")
    t.eq(plan.by_wire.display_name.name, "displayName")
    t.eq(plan.by_name.displayName.wire, "display_name")
    t.truthy(plan.known.limit)
    t.truthy(plan.has_body_members)
  end)

  t.it("is computed once per node", function()
    t.eq(S.plan(node), S.plan(node))
  end)

  t.it("a struct with only label and query members has no body members", function()
    local q =
      S.struct({ members = { S.member({ name = "q", bind = "query", schema = S.string }) } })
    t.falsy(S.plan(q).has_body_members)
  end)

  t.it("refuses a node that is not a struct", function()
    t.raises(function()
      S.plan(S.string)
    end, "struct")
  end)
end)

t.describe("schema: value helpers", function()
  t.it("lists, arrays and records", function()
    t.truthy(S.is_list_value({}))
    t.truthy(S.is_list_value({ 1, 2 }))
    t.truthy(S.is_list_value(json.array({})))
    t.falsy(S.is_list_value(json.object({})))
    t.falsy(S.is_list_value({ a = 1 }))
    t.falsy(S.is_list_value(json.null))
    t.falsy(S.is_array_value({}))
    t.truthy(S.is_array_value(json.array({})))
    t.truthy(S.is_record_value({}))
    t.falsy(S.is_record_value({ 1 }))
    t.falsy(S.is_container(secret.wrap("x")))
    t.falsy(S.is_container(json.null))
  end)

  t.it("pick_arm: list arm, discriminator, best explaining struct", function()
    local A = S.struct({
      members = {
        S.member({ name = "a", schema = S.string }),
        S.member({ name = "type", schema = S.string }),
      },
    })
    local B = S.struct({
      members = {
        S.member({ name = "b", schema = S.string }),
        S.member({ name = "type", schema = S.string }),
      },
    })
    local L = S.list(S.string)
    local U = S.union({ A, B, L }, { key = "type", values = { "a", "b" } })
    t.eq(S.pick_arm(U, { 1 }), L)
    t.eq(S.pick_arm(U, { type = "b", a = "x" }), B)
    t.eq(S.pick_arm(U, { type = "?", a = "x" }), A)
    t.eq(S.pick_arm(U, { type = "?", b = "x" }), B)
    t.eq(S.pick_arm(U, { other = 1 }), nil)
    t.eq(S.pick_arm(U, "scalar"), nil)
  end)
end)

-- Task 11: nullable nodes (Distilled's S.NullOr) for Smithy sparse lists and maps, whose
-- items and values have no member to carry `nullable`, and for a nullable rawResponse
-- output root.
t.describe("schema: nullable nodes (S.NullOr)", function()
  local keys = require("distilled.keys")
  local redact = require("distilled.redact")
  local validate = require("distilled.validate")
  local null = json.null

  local THING = S.struct({
    name = "Thing",
    members = {
      S.member({ name = "displayName", wire = "display_name", schema = S.string }),
      S.member({ name = "token", schema = S.string, sensitive = true }),
    },
  })
  local REGISTRY = { Thing = THING }
  local SPARSE_LIST = S.list(S.nullable(S.ref("Thing")))
  local SPARSE_MAP = S.map(S.nullable(S.ref("Thing")))

  t.it("S.nullable copies and marks; the shared node and a ref keep their shape", function()
    local n = S.nullable(S.string)
    t.same(n, { t = "string", nullable = true })
    t.eq(S.string.nullable, nil)
    t.same(S.nullable(S.ref("Thing")), { t = "ref", name = "Thing", nullable = true })
    t.same(S.nullable(S.sensitive(S.string)), { t = "string", sensitive = true, nullable = true })
    t.raises(function()
      S.nullable("string")
    end, "nullable expects a schema node")
  end)

  t.it("node_nullable reads the flag through refs; null and unknown nodes are nullable", function()
    t.eq(S.node_nullable(S.nullable(S.ref("Thing")), REGISTRY), true)
    t.eq(S.node_nullable(S.ref("Thing"), REGISTRY), false)
    t.eq(S.node_nullable(S.ref("N"), { N = S.nullable(S.number) }), true)
    t.eq(S.node_nullable(S.null), true)
    t.eq(S.node_nullable(S.unknown), true)
    t.eq(S.node_nullable(S.string), false)
    t.eq(S.node_nullable(S.ref("Missing"), REGISTRY), false)
    -- resolve still reaches the target: the flag does not change the node's type
    t.eq(S.resolve(S.nullable(S.ref("Thing")), REGISTRY), THING)
  end)

  t.it("validate: a sparse list keeps null items; a plain list refuses them", function()
    local v = json.decode('[{"displayName":"a"},null,{"displayName":"b"}]')
    t.eq(validate.check(SPARSE_LIST, v, REGISTRY), true)
    t.eq(validate.check(SPARSE_LIST, v, REGISTRY, { exact = true }), true)
    local r, mm = validate.check(S.list(S.ref("Thing")), v, REGISTRY)
    t.eq(r, nil)
    t.same(mm.path, { 2 })
    t.eq(mm.expected, "object")
    t.eq(validate.check(S.list(S.nullable(S.string)), json.decode('["a",null]')), true)
    local r2, mm2 = validate.check(S.list(S.string), json.decode('["a",null]'))
    t.eq(r2, nil)
    t.eq(mm2.message, "Expected string, got null at [2]")
    -- a null list itself is still refused: the flag is on the item, not the list
    t.eq(validate.check(SPARSE_LIST, null, REGISTRY), nil)
  end)

  t.it("validate: a sparse map keeps null values; a non-null value is still checked", function()
    t.eq(validate.check(SPARSE_MAP, json.decode('{"a":null,"b":{}}'), REGISTRY), true)
    local r, mm = validate.check(S.map(S.nullable(S.number)), json.decode('{"a":null,"b":"x"}'))
    t.eq(r, nil)
    t.same(mm.path, { "b" })
    t.eq(mm.expected, "number")
    t.eq(validate.check(S.map(S.number), json.decode('{"a":null}')), nil)
  end)

  t.it(
    "validate: a nullable root accepts null in strict mode too (protocol-rest.test.ts)",
    function()
      local out = S.nullable(S.ref("Thing"))
      t.eq(validate.check(out, null, REGISTRY, { exact = true }), true)
      t.eq(validate.check(out, { displayName = "x" }, REGISTRY, { exact = true }), true)
      t.eq(validate.check(S.ref("Thing"), null, REGISTRY), nil)
      -- an empty struct (opaque output) refuses null unless it is nullable
      local empty = S.struct({ members = {} })
      t.eq(validate.check(empty, null), nil)
      t.eq(validate.check(S.nullable(empty), null), true)
    end
  )

  t.it("validate: a member whose node is nullable accepts null like a nullable member", function()
    local s = S.struct({
      members = { S.member({ name = "x", schema = S.nullable(S.ref("Thing")), required = true }) },
    })
    t.eq(validate.check(s, { x = null }, REGISTRY), true)
  end)

  t.it("keys: null items and values survive renaming in both directions", function()
    local wire = json.decode('[{"display_name":"a"},null]')
    local user = keys.decode(SPARSE_LIST, wire, REGISTRY)
    t.eq(user[1].displayName, "a")
    t.eq(user[2], null)
    t.eq(#user, 2)
    t.eq(json.encode(keys.encode(SPARSE_LIST, user, REGISTRY)), '[{"display_name":"a"},null]')
    local m = keys.decode(SPARSE_MAP, json.decode('{"k":null,"j":{"display_name":"b"}}'), REGISTRY)
    t.eq(m.k, null)
    t.eq(m.j.displayName, "b")
  end)

  t.it("redact: sensitive members of sparse items are wrapped; null stays null", function()
    local v = keys.decode(SPARSE_LIST, json.decode('[{"token":"s3cret"},null]'), REGISTRY)
    t.eq(redact.holds_sensitive(SPARSE_LIST, REGISTRY), true)
    local w = redact.wrap(SPARSE_LIST, v, REGISTRY)
    t.truthy(secret.is(w[1].token))
    t.eq(w[2], null)
    local p = redact.parsed(S.list(S.nullable(S.sensitive(S.string))), { "a", null })
    t.truthy(secret.is(p[1]))
    t.eq(p[2], null)
    -- sensitive.test.ts "null stays null": a nullable sensitive unknown
    local s = S.struct({
      members = { S.member({ name = "env", schema = S.nullable(S.sensitive(S.unknown)) }) },
    })
    t.eq(redact.wrap(s, { env = null }).env, null)
  end)
end)
