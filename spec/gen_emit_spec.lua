local t = require("spec.harness")
local emit = require("distilled.gen.emit")
local compat = require("distilled.compat")

local function eval(src)
  local chunk = assert(compat.load("return " .. src, "=emit"))
  return chunk()
end

t.describe("gen.emit: literals", function()
  t.it("quotes strings as stylua's AutoPreferDouble does", function()
    t.eq(emit.string("plain"), '"plain"')
    t.eq(emit.string('say "hi"'), [['say "hi"']])
    t.eq(emit.string([[it's "both"]]), [["it's \"both\""]])
    t.eq(emit.string("a\\b\nc\td\0"), [["a\\b\nc\td\000"]])
  end)

  t.it("round-trips strings through the Lua parser", function()
    for _, s in ipairs({ "x", 'q"', "q'", "\1\2\31", "é ü 中", "\\n", "a]]b" }) do
      t.eq(eval(emit.string(s)), s)
    end
  end)

  t.it("writes whole numbers without a fraction", function()
    t.eq(emit.number(404), "404")
    t.eq(emit.number(-3), "-3")
    t.eq(emit.number(0.5), "0.5")
    t.raises(function()
      emit.number(1 / 0)
    end, "non%-finite")
  end)

  t.it("writes keys bare when they are identifiers", function()
    t.eq(emit.key("name"), "name = ")
    t.eq(emit.key("end"), '["end"] = ')
    t.eq(emit.key("url.template"), '["url.template"] = ')
    t.eq(emit.key(3), "[3] = ")
  end)
end)

t.describe("gen.emit: layout", function()
  t.it("keeps a table that fits on one line", function()
    local lines = emit.assign("x", { t = "list", item = emit.raw("S.string") })
    t.same(lines, { 'x = { t = "list", item = S.string }' })
  end)

  t.it("expands a table past 100 columns, one entry per line", function()
    local long = {}
    for i = 1, 12 do
      long[i] = "value_" .. i
    end
    local lines = emit.assign("x", { values = emit.list(long) })
    t.eq(lines[1], "x = {")
    t.eq(lines[2], "  values = {")
    t.eq(lines[3], '    "value_1",')
    t.eq(lines[#lines], "}")
    for _, l in ipairs(lines) do
      t.truthy(emit.width(l) <= 100, l)
    end
  end)

  t.it("orders record keys by FIELD_ORDER, then by name", function()
    t.eq(
      emit.inline({ zeta = 1, name = "n", t = "struct", alpha = 2 }),
      '{ t = "struct", name = "n", alpha = 2, zeta = 1 }'
    )
  end)

  t.it("writes an empty emit.list as {} and calls with literal arguments", function()
    t.eq(emit.inline(emit.list({})), "{}")
    t.eq(emit.inline(emit.call("S.ref", "Project")), 'S.ref("Project")')
  end)

  t.it("emits source that evaluates back to the data", function()
    local v = { a = { 1, 2, 3 }, ["b-c"] = { d = true }, e = "x" }
    local src = table.concat(emit.value(v), "\n")
    t.same(eval(src), v)
  end)

  t.it("comment wraps at the width", function()
    local words = string.rep("word ", 40)
    for _, l in ipairs(emit.comment(words)) do
      t.truthy(emit.width(l) <= 100)
      t.match(l, "^%-%- ")
    end
  end)

  t.it("buffer text drops trailing whitespace and ends with one newline", function()
    local b = emit.buffer():line("a  "):line(""):blank():line("b"):line("")
    t.eq(b:text(), "a\n\nb\n")
  end)
end)
