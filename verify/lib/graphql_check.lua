-- dl gen-diff, the GraphQL step (task 16): load a generated GraphQL client and exercise
-- every root and every type, in the runtime this script runs under (lua, luajit, or
-- gopher-lua via `rex do`).
--
--   lua verify/lib/graphql_check.lua <root> <clients dir> <module>
--   rex do verify/lib/graphql_check.lua root=<root> dir=<clients dir> module=<module>
--
-- Checks: the module loads and makes a client; every object type's field block parses
-- and names known types; every root builds a Query and compiles to a document (an
-- object root selects its first scalar field, or the first field of a nested object;
-- a root whose type has no reachable scalar is counted, not failed); the error classes
-- exist. Reports the load and parse times.
local rex_api = rawget(_G, "rex")
local args = {}
if rex_api then
  local a = rawget(rex_api, "args") or {}
  args.root, args.dir, args.module = a.root, a.dir, a.module
else
  args.root, args.dir, args.module = arg[1], arg[2], arg[3]
end
assert(args.root and args.dir and args.module, "usage: graphql_check.lua <root> <dir> <module>")

package.path = args.root
  .. "/lua/?.lua;"
  .. args.root
  .. "/lua/?/init.lua;"
  .. args.dir
  .. "/?.lua;"
  .. args.dir
  .. "/?/init.lua;"
  .. package.path

local compat = require("distilled.compat")
local graphql = require("distilled.graphql")

local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local failures = {}
local function fail(what)
  failures[#failures + 1] = what
end

local clock = os.clock
local t0 = clock()
local ok, M = compat.pcall(require, args.module)
local load_ms = (clock() - t0) * 1000
if not ok then
  print(
    "FAIL graphql check (" .. runtime .. "): " .. args.module .. " does not load: " .. tostring(M)
  )
  os.exit(1)
end
local ok_new, client = compat.pcall(M.new, {})
if not ok_new or type(client) ~= "table" then
  fail("new: " .. tostring(client))
end

local schema = require(args.module .. ".schema")
local t1 = clock()
local types = 0
for name in pairs(schema.objects) do
  local pok, fields = compat.pcall(function()
    return M.type(name).fields
  end)
  if not pok then
    fail("type " .. name .. ": " .. tostring(fields))
  else
    types = types + 1
  end
end
local parse_ms = (clock() - t1) * 1000

-- a field path from a type to a scalar, at most 3 levels down
local function scalar_path(meta, depth)
  local names = {}
  for fname in pairs(meta.fields) do
    names[#names + 1] = fname
  end
  table.sort(names)
  for _, fname in ipairs(names) do
    local f = meta.fields[fname]
    if f.kind == "scalar" then
      return { fname }
    end
  end
  if depth < 3 then
    for _, fname in ipairs(names) do
      local f = meta.fields[fname]
      if f.kind ~= "scalar" then
        local rest = scalar_path(f.of, depth + 1)
        if rest then
          table.insert(rest, 1, fname)
          return rest
        end
      end
    end
  end
  return nil
end

local roots, built, unreachable = 0, 0, 0
for _, name in ipairs(M.roots()) do
  roots = roots + 1
  local rok, err = compat.pcall(function()
    local q = M[name]()
    local target = q
    local meta = nil
    -- the root's shape and type, from its line in the schema data
    local is_leaf = false
    local lines = (schema.roots.query or "") .. "\n" .. (schema.roots.mutation or "")
    for line in string.gmatch(lines, "[^\n]+") do
      local export, _, shape, ty = string.match(line, "^(%S+) (%S+) (%S+) (%S+)")
      if export == name then
        is_leaf = shape == "leaf" or shape == "leaf_list"
        if not is_leaf then
          meta = M.type(ty)
        end
        break
      end
    end
    if not is_leaf then
      local path = meta and scalar_path(meta, 0)
      if not path then
        return "unreachable"
      end
      for _, fname in ipairs(path) do
        target = target[fname]
      end
    end
    local compiled, cerr = graphql.compile({ value = target })
    if not compiled then
      error(tostring(cerr), 0)
    end
    if not string.find(compiled.document, "Gql", 1, true) then
      error("no document", 0)
    end
    return "built"
  end)
  if not rok then
    fail("root " .. name .. ": " .. tostring(err))
  elseif err == "unreachable" then
    unreachable = unreachable + 1
  else
    built = built + 1
  end
end

local error_classes = 0
for tag in pairs(schema.errors or {}) do
  if M.errors[tag] == nil or M.errors[tag].tag ~= tag then
    fail("error class " .. tag .. " missing")
  else
    error_classes = error_classes + 1
  end
end

local summary = string.format(
  "graphql %s (%s): %d/%d roots built (%d with no reachable scalar), %d types parsed, %d error classes; load %.1f ms, parse all types %.1f ms",
  args.module,
  runtime,
  built,
  roots,
  unreachable,
  types,
  error_classes,
  load_ms,
  parse_ms
)
if #failures > 0 then
  print("FAIL " .. summary)
  for i = 1, math.min(#failures, 20) do
    print("  " .. failures[i])
  end
  os.exit(1)
end
print("ok   " .. summary)
return summary
