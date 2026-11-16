-- dl conform, step 1: write the request cases for a provider, from the generated
-- client's input schemas, with a seeded generator (deterministic on every runtime).
--
--   lua verify/conform/cases.lua <root> <provider>
--   -> verify/conform/cases/<provider>/requests.jsonl  (one case per line)
--
-- Per operation: "min" (required members only), "full" (every member, nested optional
-- members too, depth-bounded), and three "rand<n>" inputs drawn from awkward values
-- (percent-encoding, UTF-8, empty strings, 0, false, empty arrays/objects, explicit
-- nulls on nullable members, secrets on sensitive members). "rand3" also carries an
-- undeclared extra key. Labels never get "." / ".." here (cases/<provider>_requests.lua covers that).
local root, provider = arg[1], arg[2]
assert(root and provider, "usage: cases.lua <root> <provider>")
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local json = require("distilled.json")
local schema = require("distilled.schema")
local testing = require("distilled.testing")
local lib = require("verify.conform.lib")

local service = require(provider .. ".service")
local registry = service.shapes

local MAX_DEPTH = 5

local STRINGS = {
  "plain",
  "a b/c?d=e&f#g",
  "é漢字🙂",
  "",
  "100% +plus",
  "~-._*'()!",
  'line\nbreak\t"q"',
}
local LABELS = { "p1", "a b", "a/b", "é漢", "%2F", "x+y", "a?b#c", "~user" }
local NUMBERS = { 0, 1, -1, 42, 1.5, 1000000, 0.1 }

local gen = {}

local function pick(rng, list)
  return list[rng(#list)]
end

local function is_sensitive(member, node)
  return (member and member.sensitive) or schema.node_sensitive(node, registry)
end

-- value(node, member, mode, rng, depth) ; mode = "min" | "full" | "rand"
function gen.value(node, member, mode, rng, depth)
  local resolved = assert(schema.resolve(node, registry))
  local t = resolved.t
  if member and member.bind == "label" then
    if t == "number" then
      return mode == "rand" and pick(rng, { 1, 7, 12345 }) or 1
    end
    if t == "enum" then
      return mode == "rand" and pick(rng, resolved.values) or resolved.values[1]
    end
    return mode == "rand" and pick(rng, LABELS) or "p1"
  end
  if member and member.nullable and mode == "rand" and rng() < 0.25 then
    return json.null
  end
  local v
  if t == "string" or t == "timestamp" then
    if t == "timestamp" then
      v = "2024-01-02T03:04:05Z"
    elseif mode == "rand" then
      v = pick(rng, STRINGS)
    else
      v = mode == "full" and "full value" or "x"
    end
  elseif t == "blob" then
    v = "bytes"
  elseif t == "number" then
    v = mode == "rand" and pick(rng, NUMBERS) or (mode == "full" and 2 or 1)
  elseif t == "boolean" then
    if mode == "rand" then
      v = rng() < 0.5
    else
      v = true
    end
  elseif t == "unknown" then
    v = mode == "rand" and json.object({ k = pick(rng, STRINGS), n = 0, b = false })
      or json.object({})
  elseif t == "null" then
    v = json.null
  elseif t == "enum" then
    v = mode == "rand" and pick(rng, resolved.values) or resolved.values[1]
  elseif t == "list" then
    local n = mode == "min" and 1 or (mode == "full" and 2 or rng(0, 2))
    local out = json.array({})
    if depth < MAX_DEPTH then
      for i = 1, n do
        out[i] = gen.value(resolved.item, nil, mode, rng, depth + 1)
      end
    end
    v = out
  elseif t == "map" then
    local out = json.object({})
    if mode ~= "min" and depth < MAX_DEPTH then
      local n = mode == "full" and 1 or rng(0, 2)
      for i = 1, n do
        out["key" .. i] = gen.value(resolved.value, nil, mode, rng, depth + 1)
      end
    end
    v = out
  elseif t == "union" then
    local arm = mode == "rand" and pick(rng, resolved.arms) or resolved.arms[1]
    v = gen.value(arm, nil, mode, rng, depth + 1)
  elseif t == "struct" then
    v = gen.struct(resolved, mode, rng, depth)
  else
    error("no value for node type " .. tostring(t))
  end
  if type(v) == "string" and is_sensitive(member, node) then
    if gen.output then
      return "s3cret-" .. v -- a response body carries the plain value
    end
    return { ["$secret"] = (v == "" and "" or "s3cret-") .. v }
  end
  return v
end

function gen.struct(node, mode, rng, depth)
  local out = json.object({})
  for _, m in ipairs(node.members or {}) do
    -- outputs: only body members live in the body (header/status members come from elsewhere)
    local skip = m.bind == "status" or (gen.output and m.bind ~= nil and m.bind ~= "body")
    if not skip then
      local include = m.required
      if not include and depth < MAX_DEPTH then
        if mode == "full" then
          include = true
        elseif mode == "rand" then
          include = rng() < 0.5
        end
      end
      if include then
        out[m.name] = gen.value(m.schema, m, mode, rng, depth + 1)
      end
    end
  end
  return out
end

local names = {}
for name in pairs(service.ops) do
  names[#names + 1] = name
end
table.sort(names)

local cases = {}
for _, name in ipairs(names) do
  local op = service.ops[name]
  local input_node = assert(schema.resolve(op.input, registry))
  local rng = testing.random(lib.seed_of(name))
  local function add(kind, input)
    cases[#cases + 1] = {
      id = name .. "/" .. kind,
      op = name,
      ts = lib.ts_name(op.name),
      input = input,
    }
  end
  add("min", gen.struct(input_node, "min", rng, 0))
  add("full", gen.struct(input_node, "full", rng, 0))
  for i = 1, 3 do
    local input = gen.struct(input_node, "rand", rng, 0)
    if i == 3 then
      input.zz_extra = "undeclared"
    end
    add("rand" .. i, input)
  end
end

---------------------------------------------------------------------------------------
-- responses: per operation a success body built from the output schema ("ok-min",
-- "ok-full", "ok-rand"), then the hand-written cases in cases/<provider>_responses.lua
---------------------------------------------------------------------------------------

local responses = {}
local function add_response(c)
  local op = service.ops[c.op]
  c.ts = c.ts or lib.ts_name(op.name)
  if c.input == nil then
    local was = gen.output
    gen.output = false
    c.input = gen.struct(assert(schema.resolve(op.input, registry)), "min", nil, 0)
    gen.output = was
  end
  local r = c.response
  r.headers = r.headers or json.object({})
  if r.json ~= nil then
    r.body = assert(json.encode(r.json))
    r.json = nil
    if r.headers["content-type"] == nil then
      r.headers["content-type"] = "application/json"
    end
  end
  responses[#responses + 1] = c
end

for _, name in ipairs(names) do
  local op = service.ops[name]
  local rng = testing.random(lib.seed_of("response:" .. name))
  local out = op.output and assert(schema.resolve(op.output, registry))
  gen.output = true
  if out == nil then
    add_response({ id = name .. "/ok-empty", op = name, response = { status = op.code or 200 } })
  elseif out.t == "blob" then
    add_response({
      id = name .. "/ok-bytes",
      op = name,
      response = {
        status = op.code or 200,
        headers = { ["content-type"] = "application/octet-stream" },
        body_b64 = "AAEC/0JpbmFyeSDl/w==",
      },
    })
  else
    for _, mode in ipairs({ "min", "full", "rand" }) do
      local body = gen.value(op.output, nil, mode, rng, 0)
      add_response({
        id = name .. "/ok-" .. mode,
        op = name,
        response = { status = op.code or 200, json = body },
      })
      if mode ~= "rand" then
        -- the same body under strict validation: a body built from the schema must pass
        add_response({
          id = name .. "/ok-" .. mode .. "-strict",
          op = name,
          validation = "strict",
          response = { status = op.code or 200, json = body },
        })
      end
    end
  end
  gen.output = false
end

local resp_path = root .. "/verify/conform/cases/" .. provider .. "_responses.lua"
if lib.read(resp_path) then
  for _, c in ipairs(dofile(resp_path)) do
    add_response(c)
  end
end
lib.write_lines(root .. "/verify/conform/cases/" .. provider .. "/responses.jsonl", responses)
print(string.format("cases: %d response cases", #responses))

-- hand-written edge cases (verify/conform/cases/<provider>_requests.lua), after the generated
local hand_path = root .. "/verify/conform/cases/" .. provider .. "_requests.lua"
if lib.read(hand_path) then
  for _, c in ipairs(dofile(hand_path)) do
    c.ts = c.ts or lib.ts_name(service.ops[c.op].name)
    cases[#cases + 1] = c
  end
end

local out = root .. "/verify/conform/cases/" .. provider .. "/requests.jsonl"
lib.write_lines(out, cases)
print(string.format("cases: %d request cases for %d operations -> %s", #cases, #names, out))
