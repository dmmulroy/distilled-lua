-- dl conform, members: every operation's top-level input members (name, required) in the
-- generated Lua service against Distilled's input schema (ref/<provider>/members.jsonl).
local schema = require("distilled.schema")
local lib = require("verify.conform.lib")

local check = {}

function check.run(ctx)
  local refs = lib.read_lines(ctx.ref_dir .. "/members.jsonl")
  local results = {}
  for i, ref in ipairs(refs) do
    local result = { id = ref.op, line = i, file = "(ref) members.jsonl", case = ref, diffs = {} }
    local op = ctx.service.ops[ref.op]
    if not op then
      result.diffs[1] = { path = "op", a = ref.id, b = nil }
    else
      local node = schema.resolve(op.input, ctx.service.shapes)
      local lua = {}
      for _, m in ipairs(node.members or {}) do
        if m.bind ~= "status" then
          lua[m.name] = m.required == true
        end
      end
      for _, m in ipairs(ref.members) do
        if lua[m.name] == nil then
          result.diffs[#result.diffs + 1] = { path = "members." .. m.name, a = "present", b = nil }
        elseif lua[m.name] ~= m.required then
          result.diffs[#result.diffs + 1] =
            { path = "members." .. m.name .. ".required", a = m.required, b = lua[m.name] }
        end
        lua[m.name] = nil
      end
      for name in pairs(lua) do
        result.diffs[#result.diffs + 1] = { path = "members." .. name, a = nil, b = "present" }
      end
    end
    results[#results + 1] = result
  end
  return results
end

return check
