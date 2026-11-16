-- The generator over the real Neon model (models/neon.json, 178 operations): the trait
-- audit, and byte-identical output against the committed clients/neon/ in every runtime.
local t = require("spec.harness")
local gen = require("distilled.gen")
local traits = require("distilled.gen.traits")

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

t.describe("gen: the Neon model", function()
  local m, err = gen.model.load(t.root .. "/models/neon.json")

  t.it("loads with no problems and no warnings", function()
    t.truthy(m, err)
    t.eq(#m.operations, 178)
    t.same(m.warnings, {})
  end)

  t.it("every trait id in the model is handled or deliberately ignored", function()
    local seen = {}
    local function note(tr)
      for id in pairs(tr or {}) do
        seen[id] = true
      end
    end
    for _, id in ipairs(m.ids) do
      local def = m.shapes[id]
      note(def.traits)
      for _, mem in pairs(def.members or {}) do
        note(mem.traits)
      end
      note(def.member and def.member.traits)
      note(def.key and def.key.traits)
      note(def.value and def.value.traits)
    end
    local ids = {}
    for id in pairs(seen) do
      ids[#ids + 1] = id
      local entry = traits.lookup(id)
      t.truthy(entry, id)
      t.eq(entry.fail, nil, id)
      t.truthy(entry.handled or entry.ignored, id)
    end
    -- the 22 trait ids `jq` lists for models/neon.json
    t.eq(#ids, 22)
  end)

  t.it("regenerates clients/neon/ byte for byte", function()
    local files, gerr = gen.generate({ model = m, provider = t.root .. "/providers/neon.lua" })
    t.truthy(files, gerr)
    for _, name in ipairs(files.order) do
      local committed = read(t.root .. "/clients/neon/" .. name)
      t.truthy(committed, "clients/neon/" .. name .. " is committed")
      t.eq(#files[name], #committed, name .. " size")
      t.truthy(files[name] == committed, name .. " differs from a fresh generation")
    end
  end)
end)
