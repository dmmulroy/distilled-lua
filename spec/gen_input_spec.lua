-- verify/lib/gen_input.lua: the input synthesizer dl gen-diff builds every request with
local t = require("spec.harness")
local S = require("distilled.schema")
local json = require("distilled.json")
local synth = require("verify.lib.gen_input")

local function column_registry()
  -- starburst-galaxy's live table schema (task 26): a column requires its nested columns
  return {
    Column = S.struct({
      name = "Column",
      members = {
        S.member({ name = "name", schema = S.string, required = true }),
        S.member({ name = "nestedColumns", schema = S.list(S.ref("Column")), required = true }),
      },
    }),
  }
end

t.describe("gen_input: synthesized inputs", function()
  t.it("fills required members with placeholders", function()
    local op = {
      input = S.struct({
        members = {
          S.member({ name = "id", schema = S.string, required = true, bind = "label" }),
          S.member({ name = "count", schema = S.number, required = true }),
          S.member({ name = "note", schema = S.string }),
        },
      }),
    }
    local input = synth.input(op, {})
    t.eq(input.id, "p1")
    t.eq(input.count, 1)
    t.eq(input.note, nil)
  end)

  t.it("ends a cycle through a required list with an empty list", function()
    local op = {
      input = S.struct({
        members = {
          S.member({ name = "column", schema = S.ref("Column"), required = true }),
        },
      }),
    }
    local input, err = synth.input(op, column_registry())
    t.eq(err, nil)
    t.eq(input.column.name, "x")
    local depth, node = 0, input.column
    while #node.nestedColumns > 0 do
      depth = depth + 1
      node = node.nestedColumns[1]
    end
    t.truthy(depth > 1 and depth < synth.MAX_DEPTH, depth)
    t.eq(json.encode(node.nestedColumns), "[]")
  end)

  t.it("still refuses a cycle through required struct members", function()
    local reg = {
      Node = S.struct({
        members = { S.member({ name = "next", schema = S.ref("Node"), required = true }) },
      }),
    }
    local input, err = synth.input({ input = S.ref("Node") }, reg)
    t.eq(input, nil)
    t.match(err, "nest deeper than")
  end)
end)
