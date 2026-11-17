-- The Smithy AWS protocol tests (smithy-aws-protocol-tests 1.75.0, as Distilled's
-- packages/aws/test/protocol-tests runs them): each test service generated with the AWS
-- generator and every client request, response and error case replayed through a fake
-- transport. verify/lib/aws_protocol_tests.lua is the runner; the skipped cases are the
-- ones Distilled skips (server-only, `defaults`, @endpoint host prefix).
local t = require("spec.harness")
local runner = require("verify.lib.aws_protocol_tests")

local results

local function run()
  if not results then
    results = runner.run({ path = t.root .. "/spec/fixtures/aws/protocol-tests.json" })
  end
  return results
end

local EXPECTED = {
  JsonRpc10 = 54,
  QueryCompatibleJsonRpc10 = 3,
  JsonProtocol = 116,
  AwsQuery = 75,
  AwsEc2 = 57,
  RestJson = 233,
  RestXml = 175,
  RestXmlWithNamespace = 2,
}

t.describe("aws smithy protocol tests", function()
  local names = {}
  for name in pairs(EXPECTED) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local count = EXPECTED[name]
    t.it(name .. ": every client case passes", function()
      local r = run()
      local stats = r.by_service[name]
      t.truthy(stats, "service ran")
      local failures = {}
      for _, f in ipairs(r.failures) do
        if string.sub(f.id, 1, #name + 1) == name .. " " then
          failures[#failures + 1] = f.id .. ": " .. f.message
        end
      end
      if #failures > 0 then
        t.fail(table.concat(failures, "\n"))
      end
      t.eq(stats.passed, count)
    end)
  end
end)
