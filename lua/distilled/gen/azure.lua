-- Azure Resource Manager model support (task 20). Ports what Distilled's
-- packages/azure/scripts/generate.ts and convert.ts do to the models beyond the shared
-- generator:
--
-- - `api_version`: convert.ts folds each operation's resolved stable api-version into
--   its `smithy.api#http` trait (`apiVersion`, Azure's HttpTrait in traits.ts) and keeps
--   it as the `com.distilled.openapi#apiVersion` operation trait too. The op descriptor
--   carries it as `api_version`; distilled.protocol.azure appends `?api-version=` at call
--   time. Only the Azure protocol reads it, so a model with it under another protocol
--   fails generation (the parameter would be dropped and every ARM call refused).
-- - `prepare`: generate.ts's `markScopeLabelsGreedy` transformModel. A label that is the
--   whole leading path segment (`/{scope}/providers/...`, `/{resourceUri}/...`,
--   `/{roleAssignmentId}`) carries a full ARM id such as
--   `/subscriptions/{id}/resourceGroups/{rg}` (the specs mark these
--   `x-ms-skip-url-encoding`), so it becomes a greedy `{name+}` label that keeps its `/`.
--
-- - `operation_names`: two ARM operation ids that differ only in case (one per
--   api-version) get distinct Lua method names.
--
-- Everything else Azure needs (member names, rawResponse, nullable, sensitive, untagged
-- unions, no per-operation errors) is what the shared generator already does.
local azure = {}

azure.PROTOCOL = "distilled.protocol.azure"
azure.T_API_VERSION = "com.distilled.openapi#apiVersion"

--- azure.applies(spec) -> whether the provider spec uses the Azure protocol
function azure.applies(spec)
  return type(spec) == "table" and spec.protocol == azure.PROTOCOL
end

--- azure.api_version(ctx, op, http) -> version | nil, nil | nil, message
-- The operation's api-version: the http trait's `apiVersion`, else the apiVersion trait
-- (Distilled's foldApiVersionIntoHttp: `if (apiVersion && http && !http.apiVersion)`).
-- When both are set and differ (cognitiveservices: a preview api-version patched into
-- the http trait), the http trait's wins, as in Distilled.
function azure.api_version(ctx, op, http)
  local traits = op.def.traits or {}
  local v = http.apiVersion
  if v == nil then
    v = traits[azure.T_API_VERSION]
  end
  if v == nil then
    return nil, nil
  end
  if type(v) ~= "string" or not string.find(v, "^[%w][%w.%-]*$") then
    return nil, "api-version " .. tostring(v) .. " is not a version string"
  end
  if not azure.applies(ctx.provider) then
    return nil,
      "api-version "
        .. v
        .. ' needs the Azure protocol (provider spec protocol = "'
        .. azure.PROTOCOL
        .. '"); another protocol would drop it'
  end
  return v, nil
end

--- azure.prepare(model): rewrite leading-segment labels to greedy ones, in place
-- (markScopeLabelsGreedy: `^/\{([A-Za-z0-9_]+)\}(?=\/|$)` -> `/{$1+}`).
function azure.prepare(m)
  for _, op in ipairs(m.operations) do
    local http = op.def.traits and op.def.traits["smithy.api#http"]
    if type(http) == "table" and type(http.uri) == "string" then
      local name, rest = string.match(http.uri, "^/{([A-Za-z0-9_]+)}(.*)$")
      if name and (rest == "" or string.sub(rest, 1, 1) == "/") then
        http.uri = "/{" .. name .. "+}" .. rest
      end
    end
  end
end

local function api_version_of(op)
  local http = op.def.traits and op.def.traits["smithy.api#http"]
  local v = type(http) == "table" and http.apiVersion or nil
  if v == nil and op.def.traits then
    v = op.def.traits[azure.T_API_VERSION]
  end
  return type(v) == "string" and v or ""
end

--- azure.operation_names(m, spec) -> overrides (model op name -> method name)
-- Distilled exports ARM operation ids verbatim, so `GetSapVirtualInstance` (api-version
-- 2024-09-01) and `GetSAPVirtualInstance` (2023-04-01) of workloads are two operations;
-- snake_case makes both `get_sap_virtual_instance`. In such a group the operation with
-- the newest api-version keeps the name and every other one gets its api-version as a
-- suffix (`get_sap_virtual_instance_2023_04_01`). The provider spec's own
-- naming.operations entries win; a group the rule cannot separate (same api-version)
-- is left to naming.operation_names, which fails generation naming both.
function azure.operation_names(m, spec)
  local naming = require("distilled.gen.naming")
  local words = naming.words(spec.naming.words)
  local given = spec.naming.operations or {}
  local groups, order = {}, {}
  for _, op in ipairs(m.operations) do
    if given[op.name] == nil then
      local method = naming.snake_case(op.name, words)
      if not groups[method] then
        groups[method] = {}
        order[#order + 1] = method
      end
      local g = groups[method]
      g[#g + 1] = op
    end
  end
  local overrides = {}
  for k, v in pairs(given) do
    overrides[k] = v
  end
  for _, method in ipairs(order) do
    local g = groups[method]
    if #g > 1 then
      table.sort(g, function(a, b)
        local va, vb = api_version_of(a), api_version_of(b)
        if va ~= vb then
          return va > vb
        end
        return a.name < b.name
      end)
      for i = 2, #g do
        local v = api_version_of(g[i])
        if v ~= "" and v ~= api_version_of(g[1]) then
          overrides[g[i].name] = method .. "_" .. string.lower((string.gsub(v, "[^%w]", "_")))
        end
      end
    end
  end
  return overrides
end

return azure
