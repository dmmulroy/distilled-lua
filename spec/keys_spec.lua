local t = require("spec.harness")
local keys = require("distilled.keys")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")

local m = S.member

local THING = S.struct({
  name = "Thing",
  members = {
    m({ name = "id", schema = S.string }),
    m({ name = "displayName", wire = "display_name", schema = S.string }),
    m({ name = "tags", schema = S.list(S.string) }),
    m({ name = "meta", schema = S.map(S.ref("Meta")) }),
  },
})
local REGISTRY = {
  Meta = S.struct({
    name = "Meta",
    members = { m({ name = "createdBy", wire = "created_by", schema = S.string }) },
  }),
}

t.describe("keys: renaming", function()
  t.it("encode renames user names to wire names, decode back", function()
    local wire = keys.encode(THING, { id = "1", displayName = "W" }, REGISTRY)
    t.same(wire, { id = "1", display_name = "W" })
    t.same(
      keys.decode(THING, { id = "1", display_name = "W" }, REGISTRY),
      { id = "1", displayName = "W" }
    )
  end)

  t.it("renames inside maps and lists through refs", function()
    local wire = keys.encode(THING, { meta = { a = { createdBy = "u" } } }, REGISTRY)
    t.eq(json.encode(wire), '{"meta":{"a":{"created_by":"u"}}}')
    local back = keys.decode(THING, json.decode('{"meta":{"a":{"created_by":"u"}}}'), REGISTRY)
    t.eq(back.meta.a.createdBy, "u")
  end)

  t.it("keys the schema does not declare pass through unchanged", function()
    t.same(
      keys.encode(THING, { displayName = "W", extra = { deep = 1 } }, REGISTRY),
      { display_name = "W", extra = { deep = 1 } }
    )
    t.same(
      keys.decode(THING, { display_name = "W", other = 2 }, REGISTRY),
      { displayName = "W", other = 2 }
    )
  end)

  t.it("a declared member wins over an undeclared key that collides with its wire name", function()
    t.same(
      keys.encode(THING, { displayName = "member", display_name = "raw" }, REGISTRY),
      { display_name = "member" }
    )
  end)

  t.it("json.null and secrets pass through", function()
    local s = secret.wrap("x")
    local out = keys.encode(THING, { displayName = json.null, id = s }, REGISTRY)
    t.eq(out.display_name, json.null)
    t.eq(out.id, s)
  end)

  t.it("does not change the value it is given when it copies", function()
    local input = { displayName = "W", tags = {} }
    keys.encode(THING, input, REGISTRY)
    t.eq(input.displayName, "W")
    t.eq(input.display_name, nil)
    t.eq(getmetatable(input.tags), nil)
  end)

  t.it("a struct with no members is opaque", function()
    local OPEN = S.struct({ members = {} })
    local v = { anyKey = { x = 1 } }
    t.eq(keys.encode(OPEN, v), v)
    t.eq(keys.decode(OPEN, v), v)
  end)

  t.it("a value of the wrong kind passes through", function()
    t.eq(keys.encode(THING, "text", REGISTRY), "text")
    local arr = json.array({ 1, 2 })
    t.eq(keys.encode(THING, arr, REGISTRY), arr)
    local out = keys.encode(THING, { tags = { a = 1 } }, REGISTRY)
    t.same(out.tags, { a = 1 })
  end)

  t.it("a missing ref is treated as opaque content", function()
    local node =
      S.struct({ members = { m({ name = "x", wire = "X", schema = S.ref("Missing") }) } })
    t.same(keys.encode(node, { x = { a = 1 } }, {}), { X = { a = 1 } })
  end)

  t.it("string_encoded members stringify on encode only, element-wise, null stays null", function()
    local node = S.struct({
      members = {
        m({ name = "flag", schema = S.boolean, string_encoded = true }),
        m({ name = "nums", schema = S.list(S.number), string_encoded = true }),
        m({ name = "maybe", schema = S.boolean, string_encoded = true }),
      },
    })
    local out = keys.encode(node, { flag = true, nums = { 1, 2.5 }, maybe = json.null })
    t.eq(json.encode(out), '{"flag":"true","maybe":null,"nums":["1","2.5"]}')
    t.same(keys.decode(node, { flag = "true" }), { flag = "true" })
  end)
end)

t.describe("keys: array and object marks", function()
  t.it("an empty table at a list node is marked an array, at a map or struct an object", function()
    local out = keys.encode(THING, { displayName = "W", tags = {}, meta = {} }, REGISTRY)
    t.truthy(json.is_array(out.tags))
    t.truthy(json.is_object(out.meta))
    t.truthy(json.is_object(out))
    t.eq(json.encode(out), '{"display_name":"W","meta":{},"tags":[]}')
  end)

  t.it("a map with integer-looking keys stays an object", function()
    local node = S.map(S.string)
    t.eq(json.encode(keys.encode(node, { [1] = "a" })), '{"1":"a"}')
  end)

  t.it("verbatim subtrees are not copied: marks are set in place", function()
    local PLAIN = S.struct({
      members = {
        m({ name = "ips", schema = S.list(S.string) }),
        m({ name = "labels", schema = S.map(S.list(S.string)) }),
      },
    })
    t.truthy(keys.verbatim(PLAIN, nil, "encode"))
    local v = { ips = {}, labels = { a = {} } }
    local out = keys.encode(PLAIN, v)
    t.eq(out, v)
    t.truthy(json.is_array(v.ips))
    t.truthy(json.is_array(v.labels.a))
    t.eq(json.encode(out), '{"ips":[],"labels":{"a":[]}}')
  end)

  t.it("decode of a verbatim value returns it untouched", function()
    local v = json.decode('{"tags":["a"],"id":"1"}')
    local PLAIN = S.struct({
      members = {
        m({ name = "tags", schema = S.list(S.string) }),
        m({ name = "id", schema = S.string }),
      },
    })
    t.eq(keys.decode(PLAIN, v), v)
  end)

  t.it("verbatim is false when a member is renamed or string-encoded below", function()
    t.falsy(keys.verbatim(THING, REGISTRY, "encode"))
    local deep = S.list(
      S.map(
        S.struct({ members = { m({ name = "a", schema = S.boolean, string_encoded = true }) } })
      )
    )
    t.falsy(keys.verbatim(deep, nil, "encode"))
    t.truthy(keys.verbatim(deep, nil, "decode"))
  end)

  t.it("verbatim follows refs per registry", function()
    local node = S.struct({ members = { m({ name = "x", schema = S.ref("X") }) } })
    local renamed =
      { X = S.struct({ members = { m({ name = "a", wire = "A", schema = S.string }) } }) }
    local plain = { X = S.struct({ members = { m({ name = "a", schema = S.string }) } }) }
    t.falsy(keys.verbatim(node, renamed, "encode"))
    t.truthy(keys.verbatim(node, plain, "encode"))
  end)
end)

t.describe("keys: unions (mapKeys union arm selection)", function()
  -- arms whose wire names differ, so the chosen arm shows in the output
  local ZONE = S.struct({
    name = "Zone",
    members = {
      m({ name = "id", schema = S.string }),
      m({ name = "type", schema = S.string }),
      m({ name = "zoneName", wire = "zone_name", schema = S.string }),
    },
  })
  local ACCOUNT = S.struct({
    name = "Account",
    members = {
      m({ name = "id", schema = S.string }),
      m({ name = "type", schema = S.string }),
      m({ name = "accountName", wire = "account_name", schema = S.string }),
    },
  })
  local TAGGED = S.union({ ZONE, ACCOUNT }, { key = "type", values = { "zone", "account" } })
  local UNTAGGED = S.union({ ZONE, ACCOUNT })

  t.it("the discriminator picks the arm that key sets cannot tell apart", function()
    local merged = { id = "1", type = "account", zone_name = "z", account_name = "a" }
    local out = keys.decode(TAGGED, merged)
    t.eq(out.accountName, "a")
    t.eq(out.zone_name, "z") -- not declared by the chosen arm: passes through
    out = keys.decode(TAGGED, { id = "1", type = "zone", zone_name = "z", account_name = "a" })
    t.eq(out.zoneName, "z")
    t.eq(out.account_name, "a")
  end)

  t.it("an unknown tag falls back to best-explaining scoring", function()
    local out =
      keys.decode(TAGGED, { id = "1", type = "other", zone_name = "z", account_name = json.null })
    t.eq(out.zoneName, "z")
  end)

  t.it("without a discriminator the best-explaining arm wins (nulls do not count)", function()
    local out = keys.decode(
      UNTAGGED,
      { id = "1", type = "account", zone_name = json.null, account_name = "a" }
    )
    t.eq(out.accountName, "a")
    out = keys.encode(UNTAGGED, { id = "1", zoneName = "z" })
    t.same(out, { id = "1", zone_name = "z" })
  end)

  t.it("ties break by coverage, then declaration order", function()
    local out = keys.encode(UNTAGGED, { id = "1" })
    t.same(out, { id = "1" })
    -- both arms explain `id`; the first (Zone) is used, so zoneName would be renamed
    out = keys.encode(UNTAGGED, { id = "1", accountName = "a", zoneName = "z" })
    t.eq(out.zone_name, "z")
    t.eq(out.accountName, "a")
  end)

  t.it("an array value takes the first list arm", function()
    local U = S.union({ ZONE, S.list(ACCOUNT) })
    local out = keys.encode(U, { { accountName = "a" } })
    t.eq(json.encode(out), '[{"account_name":"a"}]')
  end)

  t.it("no arm explains the value: verbatim", function()
    local v = { unrelated = 1 }
    t.same(keys.encode(UNTAGGED, v), v)
  end)

  t.it("arms may be refs", function()
    local U = S.union(
      { S.ref("Zone"), S.ref("Account") },
      { key = "type", values = { "zone", "account" } }
    )
    local out = keys.decode(
      U,
      { type = "account", account_name = "a" },
      { Zone = ZONE, Account = ACCOUNT }
    )
    t.eq(out.accountName, "a")
  end)
end)

t.describe("keys: deep data", function()
  t.it("recursive schemas walk deep values without recursion (gopher-lua's stack)", function()
    local reg = {
      Node = S.struct({
        name = "Node",
        members = {
          m({ name = "childNode", wire = "child", schema = S.ref("Node") }),
          m({ name = "v", schema = S.number }),
        },
      }),
    }
    local root = {}
    local cur = root
    for i = 1, 600 do
      cur.v = i
      cur.childNode = {}
      cur = cur.childNode
    end
    local out = keys.encode(S.ref("Node"), root, reg)
    local depth, at = 0, out
    while at and at.child do
      depth = depth + 1
      at = at.child
    end
    t.eq(depth, 600)
    local back = keys.decode(S.ref("Node"), out, reg)
    t.eq(back.childNode.childNode.v, 3)
  end)

  t.it("a cyclic value stops at json.MAX_DEPTH instead of looping", function()
    local node =
      S.struct({ members = { m({ name = "selfRef", wire = "self", schema = S.unknown }) } })
    local reg =
      { N = S.struct({ members = { m({ name = "next", wire = "nxt", schema = S.ref("N") }) } }) }
    local cyc = {}
    cyc.next = cyc
    local out = keys.encode(S.ref("N"), cyc, reg)
    t.truthy(out.nxt)
    t.eq(json.encode(out), nil)
    t.truthy(node)
  end)
end)
