local t = require("spec.harness")
local fx = require("verify.lib.gen_fixture")
local S = require("distilled.schema")

local function service(opts)
  local files, err = fx.generate(opts)
  if not files then
    t.fail("generation failed: " .. tostring(err))
  end
  return fx.load(files["service.lua"], "ex.service"), files
end

local function member(node, name)
  for _, m in ipairs(node.members) do
    if m.name == name then
      return m
    end
  end
  t.fail("no member " .. name)
end

t.describe("gen.shapes: members and bindings", function()
  local svc = service()
  local shapes = svc.shapes

  t.it("binds label, query (wire = trait value), header (wire = trait value)", function()
    local req = shapes.GetThingRequest
    t.same(
      member(req, "thing_id"),
      { name = "thing_id", bind = "label", schema = S.string, required = true }
    )
    t.same(
      member(req, "verbose"),
      { name = "verbose", wire = "v", bind = "query", schema = S.boolean }
    )
    t.same(
      member(req, "trace"),
      { name = "trace", wire = "X-Trace", bind = "header", schema = S.string }
    )
  end)

  t.it("binds httpPayload as payload, and greedy labels from the URI", function()
    local req = shapes.PutBlobRequest
    t.eq(member(req, "body").bind, "payload")
    t.eq(member(req, "body").schema, S.blob)
    t.eq(member(req, "key").greedy, true)
    t.eq(member(shapes.GetBlobRequest, "key").greedy, true)
  end)

  t.it("uses jsonName as the wire name of a body member", function()
    local m = member(shapes.Thing, "displayName")
    t.eq(m.wire, "display_name")
    t.eq(m.bind, nil)
  end)

  t.it("marks required, nullable, sensitive (member and shape)", function()
    local thing = shapes.Thing
    t.eq(member(thing, "id").required, true)
    t.eq(member(thing, "kind").nullable, true)
    t.eq(member(thing, "secret").sensitive, true)
    t.eq(member(thing, "token").sensitive, true)
    t.eq(shapes.Token.sensitive, true)
    t.eq(member(thing, "displayName").required, nil)
  end)

  t.it("a member with @default is required in a response-only shape", function()
    t.eq(member(shapes.Thing, "count").required, true)
  end)

  t.it("maps every prelude scalar", function()
    local thing = shapes.Thing
    t.eq(member(thing, "created").schema, S.timestamp)
    t.eq(member(thing, "ratio").schema, S.number)
    t.eq(member(thing, "big").schema, S.number)
    t.eq(member(thing, "dec").schema, S.number)
    t.eq(member(thing, "small").schema, S.number)
    t.eq(member(thing, "n").schema, S.number)
    t.eq(member(thing, "count").schema, S.number)
    t.eq(member(thing, "data").schema, S.blob)
    t.eq(member(thing, "raw").schema, S.unknown)
    t.eq(member(shapes.Circle, "r").schema, S.number)
  end)

  t.it("refers to named shapes by ref, so a recursive shape is plain data", function()
    local parent = member(shapes.Thing, "parent")
    t.same(parent.schema, { t = "ref", name = "Thing" })
    t.eq(S.resolve(parent.schema, shapes), shapes.Thing)
  end)

  t.it("emits enum, intEnum, list, map and open structures", function()
    t.same(shapes.Kind, { t = "enum", base = "string", values = { "a", "b" } })
    t.same(shapes.Size, { t = "enum", base = "number", values = { 1, 2 } })
    t.same(shapes.TagList, { t = "list", item = S.string })
    t.same(shapes.LabelMap, { t = "map", value = S.string })
    t.eq(shapes.Meta.open, true)
    t.eq(shapes.Thing.open, nil)
  end)

  t.it("emits a union with the discriminator its arms pin (unionDiscriminator)", function()
    t.same(shapes.Shape, {
      t = "union",
      arms = { { t = "ref", name = "Circle" }, { t = "ref", name = "Square" } },
      discriminator = { key = "type", values = { "circle", "square" } },
    })
  end)

  t.it("the items member of a paginated output is required", function()
    t.eq(member(shapes.ListThingsResponse, "things").required, true)
  end)

  t.it("keeps the registry to reachable shapes", function()
    t.eq(shapes.ThingResponse ~= nil, true)
    -- the raw-response wrappers are not registry entries: the op output is the member
    t.eq(shapes.GetBlobResponse, nil)
    t.eq(shapes.ListNamesResponse, nil)
  end)
end)

t.describe("gen.shapes: naming policy and refusals", function()
  t.it("snake_case members: the wire name stays, named only where it differs", function()
    local svc = service({ provider = fx.provider({ naming = { members = "snake_case" } }) })
    t.eq(member(svc.shapes.Thing, "display_name").wire, nil)
  end)

  t.it("snake_case collisions fall back to the Smithy name (memberBases)", function()
    local svc = service({
      provider = fx.provider({ naming = { members = "snake_case" } }),
      replace = {
        {
          '"ratio": { "target": "smithy.api#Double" }',
          '"FooBar": { "target": "smithy.api#Double" }, "fooBar": { "target": "smithy.api#String" }',
        },
      },
    })
    t.eq(member(svc.shapes.Thing, "foo_bar").wire, "FooBar")
    t.eq(member(svc.shapes.Thing, "fooBar").wire, nil)
  end)

  t.it("refuses nullable list items (no representation in the contract)", function()
    local files, err = fx.generate({
      replace = {
        {
          '"ex.api#TagList": { "type": "list", "member": { "target": "smithy.api#String" } }',
          '"ex.api#TagList": { "type": "list", "member": { "target": "smithy.api#String", "traits": { "com.distilled.openapi#nullable": {} } } }',
        },
      },
    })
    t.eq(files, nil)
    t.match(err, "ex.api#TagList: nullable list items", true)
  end)

  t.it("refuses a label member missing from the URI", function()
    local _, err = fx.generate({
      replace = { { '"uri": "/things/{thing_id}"', '"uri": "/things/{id}"' } },
    })
    t.match(err, "label member thing_id has no {thing_id}", true)
    -- a placeholder with no member is a warning since task 12 (spec/gen_ops_spec.lua)
    t.no_match(err, "{id} in /things/{id} has no label member", true)
  end)
end)
