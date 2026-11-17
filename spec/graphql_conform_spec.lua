-- GraphQL request conformance: the Lua clients build the plans of
-- spec/fixtures/graphql/cases.json and must send exactly what Distilled's generated
-- TypeScript SDKs send for them (query text, variables, operationName), as recorded by
-- verify/conform/node/graphql_requests.mjs in spec/golden/graphql/requests.json. A case
-- the TS compiler refuses must be refused with the same GqlError message.
--
-- Regenerate the golden file after changing the cases or the clients:
--   node --conditions=bun --experimental-transform-types --no-warnings \
--     verify/conform/node/graphql_requests.mjs > spec/golden/graphql/requests.json
local t = require("spec.harness")
local graphql = require("distilled.graphql")
local json = require("distilled.json")
local secret = require("distilled.secret")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local MODULES = {
  linear = "linear",
  railway = "railway",
  expo_eas = "expo_eas",
  github = "github.graphql",
  fly_io = "fly_io.graphql",
}

local function read(path)
  local f = assert(io.open(t.root .. "/" .. path, "rb"))
  local text = f:read("*a")
  f:close()
  return assert(json.decode(text))
end

local cases = read("spec/fixtures/graphql/cases.json")
local golden = read("spec/golden/graphql/requests.json")

local function value(v)
  if type(v) ~= "table" or v == json.null then
    return v
  end
  if not json.is_array(v) and v["$secret"] ~= nil and next(v, next(v)) == nil then
    return secret.wrap(v["$secret"])
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = value(x)
  end
  if json.is_array(v) then
    json.array(out)
  end
  return out
end

-- the case language (see the Node script)
local build
build = function(sdk, node, item)
  if type(node) ~= "table" or node == json.null then
    return node
  end
  if node.lit ~= nil then
    return node.lit
  end
  if node.of ~= nil then
    return graphql.of(node.of)
  end
  if node.obj ~= nil then
    local out = {}
    for k, v in pairs(node.obj) do
      out[k] = build(sdk, v, item)
    end
    return out
  end
  local steps = node.q
  local first = steps[1]
  local q
  if first.item then
    q = item
  else
    q = sdk[first.root](first.args and value(first.args) or nil)
  end
  for i = 2, #steps do
    local step = steps[i]
    if type(step) == "string" then
      q = q[step]
    elseif step.f then
      q = q[step.f](value(step.args or {}))
    elseif step.map then
      local body = step.map
      q = graphql.map(q, function(it)
        return build(sdk, body, it)
      end)
    elseif step.filter then
      local body = step.filter
      q = graphql.filter(q, function(it)
        return build(sdk, body, it)
      end)
    end
  end
  return q
end

local function same_json(actual, expected, label)
  t.eq(json.encode(actual), json.encode(expected), label)
end

t.describe("graphql conformance: requests match Distilled's TypeScript SDKs", function()
  t.it("the golden file covers every case", function()
    local n = 0
    for _, c in ipairs(cases) do
      t.truthy(golden[c.id], "golden entry for " .. c.id)
      n = n + 1
    end
    t.truthy(n >= 20, "at least 20 cases")
  end)

  for _, c in ipairs(cases) do
    t.it(c.id, function()
      local sdk = require(MODULES[c.sdk])
      local want = golden[c.id]
      local sent = {}
      local page_path = c.pages and (c.page_path or { c.pages.q[1].root })
      local function execute(compiled)
        sent[#sent + 1] = graphql.request_body(compiled)
        if not page_path then
          return json.object({})
        end
        local more = #sent == 1
        local data = {
          edges = json.array({}),
          pageInfo = { hasNextPage = more, endCursor = more and "c1" or json.null },
        }
        for i = #page_path, 1, -1 do
          data = { [page_path[i]] = data }
        end
        return data
      end
      local value_, err
      if c.pages then
        value_, err = graphql.pages(build(sdk, c.pages), execute, "pages"):collect()
      else
        value_, err = graphql.evaluate(build(sdk, c.plan), execute)
      end
      t.eq(#sent, #want.requests, "requests sent")
      for i, req in ipairs(want.requests) do
        t.eq(sent[i].query, req.query, "query text of request " .. i)
        same_json(sent[i].variables, req.variables, "variables of request " .. i)
        t.eq(sent[i].operationName, req.operationName, "operationName")
      end
      if want.error then
        t.err(value_, err, want.error.tag)
        t.eq(err.message, want.error.message, "error message")
      else
        t.eq(err, nil, "no error")
      end
    end)
  end
end)
