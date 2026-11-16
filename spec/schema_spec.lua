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
