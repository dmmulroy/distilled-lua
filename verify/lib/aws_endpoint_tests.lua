-- Runs every `smithy.rules#endpointTests` case of the AWS models against
-- distilled.aws.endpoint (the rules interpreter), with the case's parameters.
--
--   luajit verify/lib/aws_endpoint_tests.lua [models/aws] [filter]
--   -> one line per failing case, then a summary; exit 1 when a case fails.
--
-- A case expects an endpoint ({ url, properties, headers }) or an error message.
-- Properties and headers are compared as JSON (keys sorted).
local json = require("distilled.json")
local endpoint = require("distilled.aws.endpoint")

local dir = arg and arg[1] or "models/aws"
local filter = arg and arg[2]

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

-- canonical JSON: sorted keys (distilled.json sorts object keys already)
local function canon(v)
  return json.encode(v)
end

local list = io.popen('ls "' .. dir .. '"'):read("*a")
local total, failed, files = 0, 0, 0
for name in string.gmatch(list, "[^\n]+") do
  if string.find(name, "%.json$") and (not filter or string.find(name, filter, 1, true)) then
    local doc = json.decode(read(dir .. "/" .. name))
    for _, shape in pairs(doc.shapes) do
      if shape.type == "service" then
        files = files + 1
        local rules = shape.traits["smithy.rules#endpointRuleSet"]
        local tests = shape.traits["smithy.rules#endpointTests"]
        for i, case in ipairs(tests and tests.testCases or {}) do
          total = total + 1
          local params = {}
          for k, v in pairs(case.params or {}) do
            if v ~= json.null then
              params[k] = v
            end
          end
          local got, err = endpoint.resolve(rules, params)
          local want = case.expect or {}
          local ok, why = true, nil
          if want.error ~= nil then
            if got then
              ok, why = false, "wanted error " .. want.error .. ", got " .. got.url
            elseif err ~= want.error then
              ok, why = false, "wanted error " .. want.error .. ", got error " .. tostring(err)
            end
          else
            local e = want.endpoint or {}
            if not got then
              ok, why = false, "wanted " .. tostring(e.url) .. ", got error " .. tostring(err)
            elseif got.url ~= e.url then
              ok, why = false, "url " .. got.url .. " ~= " .. tostring(e.url)
            elseif canon(got.properties) ~= canon(e.properties or {}) then
              ok, why =
                false, "properties " .. canon(got.properties) .. " ~= " .. canon(e.properties or {})
            elseif canon(got.headers) ~= canon(e.headers or {}) then
              ok, why = false, "headers " .. canon(got.headers) .. " ~= " .. canon(e.headers or {})
            end
          end
          if not ok then
            failed = failed + 1
            print(name .. " #" .. i .. ": " .. why)
          end
        end
      end
    end
  end
end
print(string.format("endpoint tests: %d services, %d cases, %d failed", files, total, failed))
os.exit(failed == 0 and 0 or 1)
