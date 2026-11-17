-- Azure model support in the generator (lua/distilled/gen/azure.lua): the api-version of
-- each operation (op.api_version), leading ARM-id labels made greedy (generate.ts
-- markScopeLabelsGreedy), method names for ARM ids that differ only in case, and the
-- generated client (the Azure protocol with its provider data).
local t = require("spec.harness")
local gen = require("distilled.gen")
local model_mod = require("distilled.gen.model")
local fx = require("verify.lib.gen_fixture")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- The Azure provider spec with a single model's names (providers/azure.lua as is).
local function azure_spec()
  local chunk =
    assert(require("distilled.compat").load(read(t.root .. "/providers/azure.lua"), "=azure"))
  local spec = chunk()
  spec.name = "az"
  spec.title = "Az"
  return spec
end

local function op_json(name, uri, method, api_version, trait_version)
  local http = '{ "method": "' .. method .. '", "uri": "' .. uri .. '", "code": 200'
  if api_version then
    http = http .. ', "apiVersion": "' .. api_version .. '"'
  end
  http = http .. " }"
  local traits = '"smithy.api#http": ' .. http
  if trait_version then
    traits = traits .. ', "com.distilled.openapi#apiVersion": "' .. trait_version .. '"'
  end
  return '"az.api#'
    .. name
    .. '": { "type": "operation", "input": { "target": "az.api#'
    .. name
    .. 'Request" }, "traits": { '
    .. traits
    .. " } }"
end

local function input_json(name, labels)
  local members = {}
  for _, l in ipairs(labels) do
    members[#members + 1] = '"'
      .. l
      .. '": { "target": "smithy.api#String", "traits": { "smithy.api#httpLabel": {}, "smithy.api#required": {} } }'
  end
  return '"az.api#'
    .. name
    .. 'Request": { "type": "structure", "members": { '
    .. table.concat(members, ", ")
    .. ' }, "traits": { "smithy.api#input": {} } }'
end

-- ops: { { name, uri, method, api_version, trait_version, labels } }
local function model(ops)
  local shapes, targets = {}, {}
  for _, o in ipairs(ops) do
    shapes[#shapes + 1] = op_json(o[1], o[2], o[3], o[4], o[5])
    shapes[#shapes + 1] = input_json(o[1], o[6] or {})
    targets[#targets + 1] = '{ "target": "az.api#' .. o[1] .. '" }'
  end
  local text = '{ "smithy": "2.0", "shapes": { "az.api#Svc": { "type": "service", "version": "1", '
    .. '"operations": [ '
    .. table.concat(targets, ", ")
    .. " ] }, "
    .. table.concat(shapes, ", ")
    .. " } }"
  return assert(model_mod.from_text(text, "az.json"))
end

local function generate(ops, spec)
  return gen.generate({ model = model(ops), provider = spec or azure_spec(), telemetry = false })
end

local function service_of(files)
  return fx.load(files["service.lua"], "az.service")
end

local BASIC = {
  {
    "GetGroup",
    "/subscriptions/{subscriptionId}/resourcegroups/{name}",
    "GET",
    "2025-04-01",
    "2025-04-01",
    { "subscriptionId", "name" },
  },
  {
    "GetLock",
    "/{scope}/providers/Microsoft.Authorization/locks/{lockName}",
    "GET",
    "2016-09-01",
    nil,
    { "scope", "lockName" },
  },
  { "GetById", "/{resourceId}", "GET", nil, "2021-04-01", { "resourceId" } },
  { "ListOps", "/providers/Microsoft.Resources/operations", "GET", "2025-04-01", nil, {} },
}

t.describe("azure gen: operations", function()
  t.it("each op descriptor carries its api-version (http trait or apiVersion trait)", function()
    local files, err = generate(BASIC)
    t.eq(err, nil)
    local svc = service_of(files)
    t.eq(svc.ops.get_group.api_version, "2025-04-01")
    t.eq(svc.ops.get_lock.api_version, "2016-09-01")
    t.eq(svc.ops.get_by_id.api_version, "2021-04-01")
    t.eq(svc.ops.list_ops.api_version, "2025-04-01")
  end)

  t.it("a leading ARM-id label becomes greedy; other labels stay plain", function()
    local svc = service_of(generate(BASIC))
    t.eq(svc.ops.get_lock.uri, "/{scope+}/providers/Microsoft.Authorization/locks/{lockName}")
    t.eq(svc.ops.get_by_id.uri, "/{resourceId+}")
    t.eq(svc.ops.get_group.uri, "/subscriptions/{subscriptionId}/resourcegroups/{name}")
    local input = require("distilled.schema").resolve(svc.ops.get_lock.input, svc.shapes)
    local greedy = {}
    for _, m in ipairs(input.members) do
      greedy[m.name] = m.greedy == true
    end
    t.eq(greedy.scope, true)
    t.eq(greedy.lockName, false)
  end)

  t.it(
    "the http trait's api-version wins over a different apiVersion trait (Distilled's fold)",
    function()
      local svc = service_of(generate({
        { "GetAgent", "/agents/{a}", "GET", "2026-07-15-preview", "2026-09-01", { "a" } },
      }))
      t.eq(svc.ops.get_agent.api_version, "2026-07-15-preview")
    end
  )

  t.it("an api-version under another protocol fails generation", function()
    local spec = fx.provider()
    local files, err = generate(BASIC, spec)
    t.eq(files, nil)
    t.match(err, "needs the Azure protocol", true)
  end)

  t.it("a malformed api-version fails generation", function()
    local files, err = generate({ { "GetX", "/x", "GET", "2025 01", nil, {} } })
    t.eq(files, nil)
    t.match(err, "is not a version string", true)
  end)

  t.it("ARM ids that differ only in case: the newest api-version keeps the name", function()
    local files, err = generate({
      { "GetSapInstance", "/sap/{n}", "GET", "2024-09-01", nil, { "n" } },
      { "GetSAPInstance", "/sap/{n}", "GET", "2023-04-01", nil, { "n" } },
    })
    t.eq(err, nil)
    local svc = service_of(files)
    t.eq(svc.ops.get_sap_instance.name, "GetSapInstance")
    t.eq(svc.ops.get_sap_instance_2023_04_01.name, "GetSAPInstance")
    t.eq(svc.ops.get_sap_instance_2023_04_01.api_version, "2023-04-01")
  end)

  t.it("a case collision with the same api-version still fails, naming both", function()
    local files, err = generate({
      { "GetSapInstance", "/sap/{n}", "GET", "2024-09-01", nil, { "n" } },
      { "GetSAPInstance", "/sap2/{n}", "GET", "2024-09-01", nil, { "n" } },
    })
    t.eq(files, nil)
    t.match(err, "operation names collide", true)
  end)

  t.it("the provider spec's naming.operations wins over the rule", function()
    local spec = azure_spec()
    spec.naming = { members = "wire", operations = { GetSAPInstance = "get_old_sap_instance" } }
    local svc = service_of(generate({
      { "GetSapInstance", "/sap/{n}", "GET", "2024-09-01", nil, { "n" } },
      { "GetSAPInstance", "/sap/{n}", "GET", "2023-04-01", nil, { "n" } },
    }, spec))
    t.eq(svc.ops.get_old_sap_instance.name, "GetSAPInstance")
    t.eq(svc.ops.get_sap_instance.name, "GetSapInstance")
  end)
end)

t.describe("azure gen: the client module", function()
  t.it("init.lua builds the Azure protocol with the provider data and plain options", function()
    local files = generate(BASIC)
    local init = files["init.lua"]
    t.match(init, 'require("distilled.protocol.azure")(service, {', true)
    t.match(init, 'token_url = "{authority_host}/{tenant_id}/oauth2/v2.0/token"', true)
    t.match(init, "bearer_token = { secret = true },", true)
    t.match(init, 'subscription_id = { type = "string" },', true)
    t.no_match(init, 'require("distilled.protocol.rest")', true)
  end)

  t.it("the README lists the Azure options with their environment variables", function()
    local readme = generate(BASIC)["README.md"]
    for _, var in ipairs({
      "AZURE_BEARER_TOKEN",
      "AZURE_SUBSCRIPTION_ID",
      "AZURE_TENANT_ID",
      "AZURE_API_BASE_URL",
      "AZURE_CLIENT_ID",
      "AZURE_CLIENT_SECRET",
    }) do
      t.match(readme, "`" .. var .. "`", true)
    end
  end)

  t.it("a model without api-versions under the Azure spec still generates", function()
    local files, err = generate({ { "GetX", "/x/{n}", "GET", nil, nil, { "n" } } })
    t.eq(err, nil)
    t.eq(service_of(files).ops.get_x.api_version, nil)
  end)
end)
