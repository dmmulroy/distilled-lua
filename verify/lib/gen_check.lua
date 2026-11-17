-- dl gen-diff, step 2: load a generated client and exercise every operation, in the
-- runtime this script runs under (lua, luajit, or gopher-lua via `rex do`).
--
--   lua verify/lib/gen_check.lua <root> <clients dir> <provider>
--   rex do verify/lib/gen_check.lua root=<root> dir=<clients dir> provider=<provider>
--
-- Checks: the service and (when distilled.client exists) the client module load; every
-- `ref` anywhere in the registry and the op descriptors resolves; every op's errors are
-- declared; every op builds a request from a minimal synthesized input through
-- request.build. Failures are reported by operation name. Multipart operations (task 08)
-- must build too, with a multipart/form-data content type and a closed body. An op with
-- `unsupported` (a gap the provider spec acknowledged, task 12: "streaming") must be
-- refused by request.build with SdkError; it counts as "acknowledged unsupported". Every
-- path placeholder gets a value, also for label members the model does not mark required
-- and placeholders with no member (task 12, proxmox `{url_seq}`).
-- A multi-model package (task 10) is checked through its index: lazy loading, every
-- listed service as above, index.new.
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
local client_note
-- the loaded client class of the module being checked (its protocol signs rpc ops)
local client_class
local shape_count, ref_count, ops_built, ops_skipped, op_count = 0, 0, 0, 0, 0
local load_ms = 0

-- check_rpc(op, name, input, service) -> ok: an RPC model's op (task 22, op.rpc) is also
-- built through its client's protocol, signed with fixed dummy credentials, so every
-- action's request is a complete POST with an authorization header
local function check_rpc(op, name, input, service)
  local protocol = client_class and client_class.protocol
  if type(protocol) ~= "table" or type(protocol.encode) ~= "function" then
    return true
  end
  local req, err = protocol.encode({
    service = service,
    host = {
      epoch = function()
        return 1700000000
      end,
    },
  }, op, input, { secret_id = "AKIDcheck", secret_key = "check", region = "ap-guangzhou" })
  if not req then
    fail("op " .. name .. ": rpc protocol encode failed: " .. tostring(err))
    return false
  elseif req.method ~= "POST" or type(req.body) ~= "string" or not req.headers.authorization then
    fail("op " .. name .. ": rpc request incomplete (" .. tostring(req.url) .. ")")
    return false
  end
  return true
end

-- check_module(module, fail): one generated client (module, module.service)
local function check_module(module, fail)
  client_class = nil
  local t0 = clock()
  local ok_service, service = compat.pcall(require, module .. ".service")
  load_ms = load_ms + (clock() - t0) * 1000
  if not ok_service then
    fail("service: does not load: " .. tostring(service))
    service = nil
  end

  -- the client module needs task 04's runtime
  if service then
    local has_client = compat.pcall(require, "distilled.client")
    if has_client then
      local ok, Class = compat.pcall(require, module)
      if not ok then
        fail("client: " .. module .. " does not load: " .. tostring(Class))
      elseif type(Class) ~= "table" or type(Class.new) ~= "function" then
        fail("client: " .. module .. " does not return a class with new")
      else
        client_note = "client loads"
        client_class = Class
      end
    else
      client_note = "client not loaded (distilled.client missing)"
    end
  end

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
      if input then
        for inner in string.gmatch(string.match(op.uri, "^[^?]*"), "{([^}]*)}") do
          local key = string.gsub(inner, "%+$", "")
          if input[key] == nil then
            input[key] = "x"
          end
        end
      end
      if not input then
        fail("op " .. name .. ": cannot synthesize an input: " .. ierr)
      elseif op.unsupported ~= nil then
        local req, err = request.build({ op = op, input = input, registry = registry })
        if req or type(err) ~= "table" or err.tag ~= "SdkError" then
          fail("op " .. name .. ": unsupported (" .. tostring(op.unsupported) .. ") but built")
        else
          ops_skipped = ops_skipped + 1
        end
      else
        local req, err = request.build({
          op = op,
          input = input,
          registry = registry,
          base_url = "https://gen-check.test/v1",
        })
        local ct = req and req.headers["content-type"] or ""
        if not req then
          fail("op " .. name .. ": request.build failed: " .. tostring(err))
        elseif req.method ~= op.method then
          fail("op " .. name .. ": method " .. tostring(req.method) .. " ~= " .. op.method)
        elseif string.sub(req.url, 1, 25) ~= "https://gen-check.test/v1" then
          fail("op " .. name .. ": url " .. tostring(req.url))
        elseif string.find(req.url, "{", 1, true) then
          fail("op " .. name .. ": unfilled placeholder in " .. req.url)
        elseif
          op.content_type == "multipart"
          and (
            string.sub(ct, 1, 30) ~= "multipart/form-data; boundary="
            or type(req.body) ~= "string"
            or string.sub(req.body, -4) ~= "--\r\n"
          )
        then
          -- multipart (task 08): built like any other op, and the body is a closed form
          fail("op " .. name .. ": multipart body not built (content-type " .. ct .. ")")
        elseif op.rpc ~= nil and not check_rpc(op, name, input, service) then
          -- failure reported by check_rpc
        else
          ops_built = ops_built + 1
        end
      end
    end
  end
end

-- A package with several models (task 10): clients/<pkg>/init.lua is an index and each
-- service is a module <pkg>.<service>. A single-model package has <pkg>/service.lua.
local single = io.open(args.dir .. "/" .. args.provider .. "/service.lua", "rb")
local layout_note
if single then
  single:close()
  check_module(args.provider, fail)
else
  local services = {}
  local ok, index = compat.pcall(require, args.provider)
  if not ok then
    fail("index: " .. args.provider .. " does not load: " .. tostring(index))
  elseif type(index) ~= "table" or type(index.services) ~= "table" then
    fail("index: " .. args.provider .. " has neither service.lua nor an index with services")
  else
    for i, name in ipairs(index.services) do
      services[i] = name
      if i > 1 and not (services[i - 1] < name) then
        fail("index: services are not sorted and unique at " .. name)
      end
    end
    if #services == 0 then
      fail("index: lists no service")
    end
    -- lazy: requiring the index loaded no service
    for _, name in ipairs(services) do
      if package.loaded[args.provider .. "." .. name] ~= nil then
        fail("index: requiring it loaded " .. args.provider .. "." .. name)
      end
    end
    if index.no_such_service ~= nil then
      fail("index: an unknown name is not nil")
    end
    for _, name in ipairs(services) do
      local module = args.provider .. "." .. name
      check_module(module, function(what)
        fail(module .. ": " .. what)
      end)
      if index[name] ~= package.loaded[module] then
        fail("index." .. name .. " is not require(" .. module .. ")")
      end
    end
    -- index.new: one client per service, built on first use with the shared options
    if #services > 0 and type(index.new) == "function" then
      local clients = index.new({})
      local first = services[1]
      if rawget(clients, first) ~= nil then
        fail("index.new: built a client before it was used")
      end
      local client = clients[first]
      if type(client) ~= "table" or type(client.with) ~= "function" then
        fail("index.new: clients." .. first .. " is not a client")
      elseif clients[first] ~= client then
        fail("index.new: clients." .. first .. " is built again on each use")
      end
      if clients.no_such_service ~= nil then
        fail("index.new: an unknown name is not nil")
      end
    else
      fail("index: no new function")
    end
  end
  layout_note = #services .. " services"
end

for _, n in ipairs(notes) do
  print("note " .. n)
end
for _, f in ipairs(failures) do
  print("FAIL " .. f)
end
local summary = string.format(
  "%s gen-check %s: %s%d shapes, %d refs resolved, %d/%d ops built, %d acknowledged unsupported; "
    .. "service load %.1f ms; %s",
  #failures == 0 and "ok" or "FAIL",
  runtime,
  layout_note and (layout_note .. ", ") or "",
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
