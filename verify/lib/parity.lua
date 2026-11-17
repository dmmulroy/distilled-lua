-- dl parity (task 10): how far the Lua clients are from Distilled's published SDKs.
--
--   lua verify/lib/parity.lua <root> <distilled packages dir>
--
-- Per package: the TypeScript operation count (`API.make(`, `API.makePaginated(` and
-- `API.makeStreaming(` in src/services/*.ts, the count of tasks/notes/ts-op-counts.txt),
-- the Lua operation count (`ops.<name> = ` entries in clients/<lua>/service.lua or
-- clients/<lua>/*/service.lua, and in service/ops_NNN.lua of a split service, task 18),
-- models generated / models with operations (Distilled
-- skips models without any), the missing operations (TS - Lua) and whether a provider
-- spec exists. Prints a table and writes verify/features/parity.md.
--
-- Stock lua or luajit only: it lists directories and greps through io.popen (verify tool,
-- not library code).
local root, packages = arg[1], arg[2]
assert(root and packages, "usage: lua verify/lib/parity.lua <root> <distilled packages dir>")

local function q(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function run(cmd)
  local p = assert(io.popen("( " .. cmd .. " ) 2>/dev/null"))
  local out = p:read("*a")
  p:close()
  return out
end

local function lines(cmd)
  local list = {}
  for line in string.gmatch(run(cmd), "[^\n]+") do
    list[#list + 1] = line
  end
  return list
end

local function count(cmd)
  return tonumber((string.match(run(cmd), "%d+"))) or 0
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

-- ops_in(dir): the operations of the client in dir (service.lua, plus the
-- service/ops_NNN.lua files of a split service, task 18)
local function ops_in(dir)
  return count(
    "cat "
      .. q(dir .. "/service.lua")
      .. " "
      .. q(dir .. "/service")
      .. "/ops_*.lua 2>/dev/null | grep -c -E '^ops\\.[A-Za-z0-9_]+ =( |$)'"
  )
end

local rows = {}
local graphql = {}
for _, pkg in ipairs(lines("ls -1 " .. q(packages) .. " | LC_ALL=C sort")) do
  local dir = packages .. "/" .. pkg
  local has_services = count("ls " .. q(dir .. "/src/services") .. " | grep -c '\\.ts$'") > 0
  if has_services then
    local lua = string.gsub(pkg, "-", "_")
    local ts = count(
      "cat "
        .. q(dir .. "/src/services")
        .. "/*.ts | grep -o -E 'API\\.make(Paginated|Streaming)?\\(' | wc -l"
    )
    local models_total = count(
      'grep -l -E \'"type": ?"operation"\' ' .. q(dir .. "/.generated-specs") .. "/*.json | wc -l"
    )
    local client = root .. "/clients/" .. lua
    local lua_ops, generated = 0, 0
    if exists(client .. "/service.lua") then
      generated = 1
      lua_ops = ops_in(client)
    else
      for _, svc in ipairs(lines("ls -1 " .. q(client) .. "/*/service.lua")) do
        generated = generated + 1
        lua_ops = lua_ops + ops_in((string.gsub(svc, "/service%.lua$", "")))
      end
    end
    rows[#rows + 1] = {
      pkg = pkg,
      ts = ts,
      lua = lua_ops,
      generated = generated,
      total = models_total,
      spec = exists(root .. "/providers/" .. lua .. ".lua"),
    }
  elseif exists(dir .. "/src/graphql.ts") then
    graphql[#graphql + 1] = pkg
  end
end

local totals = { ts = 0, lua = 0, generated = 0, total = 0, specs = 0, done = 0 }
for _, r in ipairs(rows) do
  totals.ts = totals.ts + r.ts
  totals.lua = totals.lua + r.lua
  totals.generated = totals.generated + r.generated
  totals.total = totals.total + r.total
  totals.specs = totals.specs + (r.spec and 1 or 0)
  if r.ts > 0 and r.lua >= r.ts then
    totals.done = totals.done + 1
  end
end

local commit = string.match(run("git -C " .. q(packages) .. " rev-parse --short HEAD"), "%w+")
  or "unknown"

-- text table (stdout)
local function pad(s, n, right)
  s = tostring(s)
  if right then
    return string.rep(" ", n - #s) .. s
  end
  return s .. string.rep(" ", n - #s)
end
local w = 8
for _, r in ipairs(rows) do
  w = math.max(w, #r.pkg)
end
print(
  pad("package", w)
    .. "  "
    .. pad("TS ops", 7, true)
    .. "  "
    .. pad("Lua ops", 7, true)
    .. "  "
    .. pad("models", 9, true)
    .. "  "
    .. pad("missing", 7, true)
    .. "  spec"
)
for _, r in ipairs(rows) do
  print(
    pad(r.pkg, w)
      .. "  "
      .. pad(r.ts, 7, true)
      .. "  "
      .. pad(r.lua, 7, true)
      .. "  "
      .. pad(r.generated .. "/" .. r.total, 9, true)
      .. "  "
      .. pad(r.ts - r.lua, 7, true)
      .. "  "
      .. (r.spec and "yes" or "-")
  )
end
print(
  pad("total", w)
    .. "  "
    .. pad(totals.ts, 7, true)
    .. "  "
    .. pad(totals.lua, 7, true)
    .. "  "
    .. pad(totals.generated .. "/" .. totals.total, 9, true)
    .. "  "
    .. pad(totals.ts - totals.lua, 7, true)
    .. "  "
    .. totals.specs
)
local pct = totals.ts > 0 and (100 * totals.lua / totals.ts) or 0
local summary = string.format(
  "parity: %d of %d TS operations (%.1f%%) in %d packages; %d packages complete, %d provider specs",
  totals.lua,
  totals.ts,
  pct,
  #rows,
  totals.done,
  totals.specs
)
print(summary)

-- verify/features/parity.md
local md = {
  "# Parity with Distilled's SDKs",
  "",
  "Generated by `verify/dl parity` (verify/lib/parity.lua). Do not edit; rerun it after",
  "`verify/dl gen-all`. Distilled at `" .. commit .. "`.",
  "",
  "- **TS ops**: `API.make(`, `API.makePaginated(` and `API.makeStreaming(` in the package's",
  "  `src/services/*.ts` (what `tasks/notes/ts-op-counts.txt` counts).",
  "- **Lua ops**: operations in the committed clients (`clients/<lua>/`).",
  "- **models**: models generated / models with operations in `.generated-specs`",
  "  (Distilled skips models without operations).",
  "- **missing**: TS ops - Lua ops (negative: the Lua client has more).",
  "- **spec**: `providers/<lua>.lua` exists, so `verify/dl gen-all` generates the package.",
  "",
  "**" .. summary .. ".**",
  "",
  "| Package | TS ops | Lua ops | Models | Missing | Spec |",
  "| --- | ---: | ---: | ---: | ---: | --- |",
}
for _, r in ipairs(rows) do
  md[#md + 1] = string.format(
    "| %s | %d | %d | %d/%d | %d | %s |",
    r.pkg,
    r.ts,
    r.lua,
    r.generated,
    r.total,
    r.ts - r.lua,
    r.spec and "yes" or ""
  )
end
md[#md + 1] = string.format(
  "| **total** | %d | %d | %d/%d | %d | %d |",
  totals.ts,
  totals.lua,
  totals.generated,
  totals.total,
  totals.ts - totals.lua,
  totals.specs
)
md[#md + 1] = ""
if #graphql > 0 then
  md[#md + 1] = "GraphQL packages (no `src/services`, not counted): "
    .. table.concat(graphql, ", ")
    .. "."
  md[#md + 1] = ""
end
local path = root .. "/verify/features/parity.md"
local f = assert(io.open(path, "wb"))
f:write(table.concat(md, "\n"))
f:close()
print("wrote verify/features/parity.md")
