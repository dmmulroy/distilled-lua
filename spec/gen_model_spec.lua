local t = require("spec.harness")
local model = require("distilled.gen.model")
local ordered = require("distilled.gen.json_ordered")
local json = require("distilled.json")
local fx = require("verify.lib.gen_fixture")

t.describe("gen.json_ordered", function()
  t.it("keeps object key order", function()
    local doc, order = ordered.decode('{"z":1,"a":{"y":2,"b":3},"m":[1,null,{"k":true}]}')
    t.same(order[doc], { "z", "a", "m" })
    t.same(order[doc.a], { "y", "b" })
    t.eq(doc.m[2], json.null)
    t.eq(#doc.m, 3)
    t.eq(doc.m[3].k, true)
  end)

  t.it("decodes escapes and surrogate pairs", function()
    local doc = ordered.decode('["a\\"b\\\\c\\n", "\\u00e9", "\\ud83d\\ude00", "\\ud800x"]')
    t.eq(doc[1], 'a"b\\c\n')
    t.eq(doc[2], "é")
    t.eq(doc[3], "😀")
    t.eq(doc[4], "\239\191\189x")
  end)

  t.it("reports where a document is broken", function()
    local v, err = ordered.decode('{"a": 1,\n "b": }')
    t.eq(v, nil)
    t.match(err, "line 2", true)
    v, err = ordered.decode("[1, 2")
    t.eq(v, nil)
    t.match(err, "expected , or ]", true)
    v, err = ordered.decode('"open')
    t.match(err, "unterminated string", true)
    v, err = ordered.decode("[1] x")
    t.match(err, "trailing", true)
  end)

  t.it("nests deeply without recursion", function()
    local text = string.rep("[", 3000) .. string.rep("]", 3000)
    local doc = ordered.decode(text)
    t.eq(type(doc), "table")
  end)
end)

t.describe("gen.model: loading", function()
  t.it("indexes the fixture: service, operations sorted by name", function()
    local m = fx.model()
    t.truthy(m)
    t.eq(m.service_id, "ex.api#Svc")
    local names = {}
    for i, op in ipairs(m.operations) do
      names[i] = op.name
    end
    t.same(names, { "GetBlob", "GetThing", "ListNames", "ListThings", "PutBlob" })
    t.eq(m.namespace, "ex.api")
  end)

  t.it("keeps member declaration order", function()
    local m = fx.model()
    local list = m:members(m.shapes["ex.api#GetThingRequest"])
    t.eq(list[1].name, "thing_id")
    t.eq(list[2].name, "verbose")
    t.eq(list[3].name, "trace")
  end)

  t.it("synthesizes a named structure for Unit output (ensureNamedIo)", function()
    local m = fx.model()
    for _, op in ipairs(m.operations) do
      if op.name == "PutBlob" then
        t.eq(op.output, "ex.api#PutBlobResponse")
        t.eq(m.shapes[op.output].type, "structure")
      end
    end
  end)

  t.it("appends the service's errors to every operation (inheritServiceErrors)", function()
    local m = fx.model()
    for _, op in ipairs(m.operations) do
      t.eq(op.errors[#op.errors], "ex.api#Throttled")
      if op.name == "GetThing" then
        t.same(op.errors, { "ex.api#NotFound", "ex.api#Throttled" })
      end
    end
  end)

  t.it("hashes the model text deterministically", function()
    t.eq(model.hash(""), "fnv1a32:811c9dc5")
    t.eq(model.hash("a"), "fnv1a32:e40c292c")
    t.eq(model.hash("foobar"), "fnv1a32:bf9cf968")
  end)
end)

t.describe("gen.model: validation names the shape", function()
  t.it("fails on a dangling target", function()
    local m, err =
      fx.model({ replace = { { '"target": "ex.api#Kind"', '"target": "ex.api#Gone"' } } })
    t.eq(m, nil)
    t.match(err, "ex.api#Thing$kind: dangling target ex.api#Gone", true)
  end)

  t.it("fails on an unknown prelude shape", function()
    local _, err = fx.model({ replace = { { '"smithy.api#Double" }', '"smithy.api#Quad" }' } } })
    t.match(err, "unknown prelude shape smithy.api#Quad", true)
  end)

  t.it("fails on an unknown trait in a guarded namespace", function()
    for _, id in ipairs({
      "smithy.api#httpFoo",
      "com.distilled.openapi#newThing",
      "distilled.retry#other",
      "com.distilled.telemetry#extra",
    }) do
      local _, err = fx.model({
        replace = { { '"smithy.api#jsonName": "display_name"', '"' .. id .. '": {}' } },
      })
      t.match(err, "ex.api#Thing$displayName: unsupported trait " .. id, true)
    end
  end)

  t.it("warns on an unknown trait elsewhere", function()
    local m = fx.model({
      replace = { { '"smithy.api#jsonName": "display_name"', '"acme.custom#flag": {}' } },
    })
    t.truthy(m)
    t.match(m.warnings[1], "ignored unknown trait acme.custom#flag", true)
  end)

  t.it("fails on known traits the runtime cannot honour", function()
    local _, err = fx.model({
      replace = { { '"smithy.api#httpQuery": "v"', '"smithy.api#httpQueryParams": {}' } },
    })
    t.match(err, "httpQueryParams", true)
    t.match(err, "no binding", true)
  end)

  t.it("fails when two namespaces share a local name", function()
    local _, err = fx.model({
      extra = '"other.ns#Kind": { "type": "list", "member": { "target": "smithy.api#String" } }',
    })
    t.match(err, "local name Kind is also used by", true)
  end)

  t.it("fails on an error without smithy.api#error", function()
    local _, err = fx.model({
      replace = {
        {
          '"smithy.api#error": "client", "smithy.api#httpError": 404',
          '"smithy.api#httpError": 404',
        },
      },
    })
    t.match(err, "has no smithy.api#error trait", true)
  end)

  t.it("fails on invalid JSON and on a non-model", function()
    local _, err = model.from_text("{", "x.json")
    t.match(err, "x.json: not valid JSON", true)
    _, err = model.from_text("[]", "y.json")
    t.match(err, "not a Smithy JSON model", true)
  end)
end)

t.describe("gen.model: boolean string enums", function()
  t.it('makes request-only "true"/"false" enum members string-encoded booleans', function()
    local extra = [["ex.api#Flag": { "type": "enum", "members": {
        "T": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "true" } },
        "F": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "false" } } } }]]
    local m = fx.model({
      extra = extra,
      replace = {
        {
          '"verbose": { "target": "smithy.api#Boolean", "traits": { "smithy.api#httpQuery": "v" } }',
          '"verbose": { "target": "ex.api#Flag", "traits": { "smithy.api#httpQuery": "v" } }',
        },
      },
    })
    local mem = m.shapes["ex.api#GetThingRequest"].members.verbose
    t.eq(mem.target, "smithy.api#Boolean")
    t.truthy(mem.traits["distilled.protocols#stringEncoded"])
  end)
end)
