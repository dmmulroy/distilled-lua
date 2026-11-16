-- dl gen-diff, step 2: load a generated client and exercise every operation, in the
-- runtime this script runs under (lua, luajit, or gopher-lua via `rex do`).
--
--   lua verify/lib/gen_check.lua <root> <clients dir> <provider>
--   rex do verify/lib/gen_check.lua root=<root> dir=<clients dir> provider=<provider>
--
-- Checks: the service and (when distilled.client exists) the client module load; every
-- `ref` anywhere in the registry and the op descriptors resolves; every op's errors are
-- declared; every op builds a request from a minimal synthesized input through
-- request.build. Failures are reported by operation name. Operations the provider spec
-- acknowledged as unsupported (multipart) must fail with exactly that SdkError.
local rex_api = rawget(_G, "rex")
local args = {}
if rex_api then
  local a = rawget(rex_api, "args") or {}
  args.root, args.dir, args.provider = a.root, a.dir, a.provider
else
  args.root, args.dir, args.provider = arg[1], arg[2], arg[3]
end
assert(args.root and args.dir and args.provider, "usage: gen_check.lua <root> <dir> <provider>")

package.path = args.root
  .. "/lua/?.lua;"
  .. args.root
  .. "/lua/?/init.lua;"
  .. args.root
  .. "/?.lua;"
  .. args.dir
  .. "/?.lua;"
  .. args.dir
  .. "/?/init.lua;"
  .. package.path

local compat = require("distilled.compat")
local request = require("distilled.request")
local synth = require("verify.lib.gen_input")

local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local failures = {}
local notes = {}
local function fail(what)
  failures[#failures + 1] = what
end

local clock = os.clock
local t0 = clock()
local ok_service, service = compat.pcall(require, args.provider .. ".service")
local load_ms = (clock() - t0) * 1000
if not ok_service then
  fail("service: does not load: " .. tostring(service))
  service = nil
end

-- the client module needs task 04's runtime
local client_note
if service then
  local has_client = compat.pcall(require, "distilled.client")
  if has_client then
    local ok, Class = compat.pcall(require, args.provider)
    if not ok then
      fail("client: " .. args.provider .. " does not load: " .. tostring(Class))
    elseif type(Class) ~= "table" or type(Class.new) ~= "function" then
      fail("client: " .. args.provider .. " does not return a class with new")
    else
      client_note = "client loads"
    end
  else
    client_note = "client not loaded (distilled.client missing)"
  end
end

local shape_count, ref_count, ops_built, ops_skipped, op_count = 0, 0, 0, 0, 0

if service then
  local registry = service.shapes
  -- resolve every ref reachable from any registry entry or op descriptor (explicit stack)
  local seen = {}
  local stack = {}
  local function push(node, where)
    if type(node) == "table" and not seen[node] then
      stack[#stack + 1] = { node = node, where = where }
    end
  end
  local names = {}
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    shape_count = shape_count + 1
    push(registry[name], "shape " .. name)
  end
  local op_names = {}
  for name in pairs(service.ops) do
    op_names[#op_names + 1] = name
  end
  table.sort(op_names)
  for _, name in ipairs(op_names) do
    local op = service.ops[name]
    push(op.input, "op " .. name .. " input")
    push(op.output, "op " .. name .. " output")
  end
  while #stack > 0 do
    local e = stack[#stack]
    stack[#stack] = nil
    local node = e.node
    if not seen[node] then
      seen[node] = true
      if node.t == "ref" then
        ref_count = ref_count + 1
        if registry[node.name] == nil then
          fail(e.where .. ": ref " .. tostring(node.name) .. " does not resolve")
        end
      elseif node.t == "struct" then
        for _, m in ipairs(node.members or {}) do
          push(m.schema, e.where .. "." .. tostring(m.name))
        end
      elseif node.t == "list" then
        push(node.item, e.where .. "[]")
      elseif node.t == "map" then
        push(node.value, e.where .. "{}")
      elseif node.t == "union" then
        for i, a in ipairs(node.arms or {}) do
          push(a, e.where .. "|" .. i)
        end
      elseif type(node.t) ~= "string" then
        fail(e.where .. ": not a schema node")
      end
    end
  end

  for _, name in ipairs(op_names) do
    op_count = op_count + 1
    local op = service.ops[name]
    for _, tag in ipairs(op.errors or {}) do
      if service.errors[tag] == nil then
        fail("op " .. name .. ": error " .. tag .. " is not in service.errors")
      end
    end
    local input, ierr = synth.input(op, registry)
    if not input then
      fail("op " .. name .. ": cannot synthesize an input: " .. ierr)
    else
      local req, err = request.build({
        op = op,
        input = input,
        registry = registry,
        base_url = "https://gen-check.test/v1",
      })
      if op.content_type == "multipart" then
        if req then
          ops_built = ops_built + 1
        elseif err and err.tag == "SdkError" and string.find(err.message, "multipart", 1, true) then
          ops_skipped = ops_skipped + 1
          notes[#notes + 1] = "op " .. name .. ": multipart refused by request.build (acknowledged)"
        else
          fail("op " .. name .. ": " .. tostring(err))
        end
      elseif not req then
        fail("op " .. name .. ": request.build failed: " .. tostring(err))
      elseif req.method ~= op.method then
        fail("op " .. name .. ": method " .. tostring(req.method) .. " ~= " .. op.method)
      elseif string.sub(req.url, 1, 25) ~= "https://gen-check.test/v1" then
        fail("op " .. name .. ": url " .. tostring(req.url))
      elseif string.find(req.url, "{", 1, true) then
        fail("op " .. name .. ": unfilled placeholder in " .. req.url)
      else
        ops_built = ops_built + 1
      end
    end
  end
end

for _, n in ipairs(notes) do
  print("note " .. n)
end
for _, f in ipairs(failures) do
  print("FAIL " .. f)
end
local summary = string.format(
  "%s gen-check %s: %d shapes, %d refs resolved, %d/%d ops built, %d acknowledged unsupported; "
    .. "service load %.1f ms; %s",
  #failures == 0 and "ok" or "FAIL",
  runtime,
  shape_count,
  ref_count,
  ops_built,
  op_count,
  ops_skipped,
  load_ms,
  tostring(client_note)
)
print(summary)
if #failures > 0 then
  if rex_api then
    error(summary, 0)
  end
  os.exit(1)
end
return summary
