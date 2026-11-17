-- Load cost of one generated client (task 18, large models), in the runtime it runs under:
--
--   lua verify/lib/load_bench.lua <root> <clients dir> <module> [op|-] [stop]
--   rex do verify/lib/load_bench.lua root=<root> dir=<clients dir> module=<module> [op=<op>]
--          [stop=require|call|all]
--
-- Prints one line: `require` time of the client module, memory after it (KB, from
-- collectgarbage; gopher-lua has none: "-"), then one call of an operation (the given
-- one, else the first by name) through a scripted transport with a synthesized minimal
-- input: its time, the memory after it, and how many shape files it loaded (split
-- layout). Last, the time to load every remaining shape (`all`). os.clock is CPU time in
-- lua/luajit and wall time in gopher-lua; the driver (verify/lib/big_models.sh) adds the
-- process's maximum resident set size.
local rex_api = rawget(_G, "rex")
local a = rex_api and rawget(rex_api, "args") or {}
local root = a.root or arg[1]
local dir = a.dir or arg[2]
local module = a.module or arg[3]
local op_name = a.op or (arg and arg[4])
-- stop = "require" | "call" | "all" (default): end after that step, so the driver can
-- read the resident set size of each step from its own process
local stop = a.stop or (arg and arg[5]) or "all"
if op_name == "" or op_name == "-" then
  op_name = nil
end
assert(root and dir and module, "usage: load_bench.lua <root> <dir> <module> [op]")
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. dir
  .. "/?.lua;"
  .. dir
  .. "/?/init.lua;"
  .. package.path

local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)

local function kb()
  collectgarbage("collect")
  local n = collectgarbage("count")
  if type(n) ~= "number" then
    return "-"
  end
  return string.format("%.0f", n)
end

-- the runtime modules first, so the numbers are the client's own
require("distilled.client")
require("distilled.protocol.rest")
require("distilled.testing")
local synth = require("verify.lib.gen_input")
local base_kb = kb()

local t0 = os.clock()
local Class = require(module)
local require_ms = (os.clock() - t0) * 1000
local require_kb = kb()

if stop == "require" then
  local line = string.format("%-7s require %.1f ms, %s KB", runtime, require_ms, require_kb)
  print(line)
  return line
end

local service = require(module .. ".service")
local function loaded_chunks()
  local n = 0
  for _, m in ipairs(service.shape_chunks or {}) do
    if package.loaded[m] ~= nil then
      n = n + 1
    end
  end
  return n
end
local before = loaded_chunks()

if not op_name then
  local names = {}
  for name in pairs(service.ops) do
    names[#names + 1] = name
  end
  table.sort(names)
  op_name = names[1]
end
local op = service.ops[op_name]
assert(op, "no operation " .. tostring(op_name))

local testing = require("distilled.testing")
local host = testing.host({
  env = setmetatable({}, {
    __index = function()
      return "bench-key"
    end,
  }),
  responses = { { status = op.code or 200, body = {} } },
})
local client = Class.new({ host = host, validation = "lenient", retry = "none" })
local t1 = os.clock()
local input, ierr = synth.input(op, service.shapes)
local call_note = "ok"
if not input then
  call_note = "no input: " .. tostring(ierr)
else
  local _, err = client[op_name](client, input)
  if err then
    call_note = "err " .. tostring(err.tag)
  end
end
local call_ms = (os.clock() - t1) * 1000
local call_kb = kb()
local after = loaded_chunks()

local t2 = os.clock()
for _, m in ipairs(stop == "all" and service.shape_chunks or {}) do
  for name in pairs(require(m)) do
    local _ = service.shapes[name]
  end
end
local all_ms = (os.clock() - t2) * 1000

local line = string.format(
  "%-7s require %.1f ms, %s KB (runtime %s KB); call %s %.1f ms (%s), %s KB, %d/%d shape files; all shapes +%.1f ms",
  runtime,
  require_ms,
  require_kb,
  base_kb,
  op_name,
  call_ms,
  call_note,
  call_kb,
  after - before,
  #(service.shape_chunks or {}),
  all_ms
)
print(line)
return line
