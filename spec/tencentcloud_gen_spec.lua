-- RPC models in the generator (gen/rpc.lua, provider spec `rpc`): operations without
-- smithy.api#http, as in Tencent Cloud's models, and the committed clients/tencentcloud.
local t = require("spec.harness")
local fx = require("verify.lib.gen_fixture")
local gen = require("distilled.gen")
local provider = require("distilled.gen.provider")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

-- a two-operation Tencent-style model (no service shape, as convert.ts writes them)
local MODEL = [[
{
  "smithy": "2.0",
  "metadata": {
    "com.distilled.telemetry#service": { "system": "tencentcloud-api", "propagation": "w3c" }
  },
  "shapes": {
    "com.tencentcloud.demo#DescribeThings": {
      "type": "operation",
      "input": { "target": "com.tencentcloud.demo#DescribeThingsRequest" },
      "output": { "target": "com.tencentcloud.demo#DescribeThingsResponse" },
      "traits": {
        "com.tencentcloud#action": { "service": "demo", "version": "2020-01-01", "action": "DescribeThings" },
        "com.distilled.telemetry#operation": { "name": "TencentCloud.DescribeThings", "method": "demo/DescribeThings" },
        "smithy.api#documentation": "List things.\n\nMore."
      }
    },
    "com.tencentcloud.demo#Thing_": {
      "type": "operation",
      "input": { "target": "com.tencentcloud.demo#ThingRequest" },
      "output": { "target": "com.tencentcloud.demo#ThingResponse" },
      "traits": {
        "com.tencentcloud#action": { "service": "demo", "version": "2020-01-01", "action": "Thing" }
      }
    },
    "com.tencentcloud.demo#DescribeThingsRequest": {
      "type": "structure",
      "members": {
        "Limit": { "target": "smithy.api#Long" },
        "Ids": { "target": "com.tencentcloud.demo#IdList" },
        "region": { "target": "smithy.api#String", "traits": { "smithy.api#httpHeader": "X-TC-Region" } }
      }
    },
    "com.tencentcloud.demo#DescribeThingsResponse": {
      "type": "structure",
      "members": {
        "TotalCount": { "target": "smithy.api#Long" },
        "RequestId": { "target": "smithy.api#String" }
      }
    },
    "com.tencentcloud.demo#ThingRequest": {
      "type": "structure",
      "members": {
        "region": { "target": "smithy.api#String", "traits": { "smithy.api#httpHeader": "X-TC-Region" } }
      }
    },
    "com.tencentcloud.demo#ThingResponse": {
      "type": "structure",
      "members": { "RequestId": { "target": "smithy.api#String" } }
    },
    "com.tencentcloud.demo#IdList": {
      "type": "list",
      "member": { "target": "smithy.api#String" }
    }
  }
}
]]

local function spec(rpc)
  return {
    name = "demo",
    title = "Demo",
    unknown_tag = "UnknownTencentCloudError",
    parse_tag = "TencentCloudParseError",
    rpc = rpc or {
      protocol = "distilled.protocol.tencentcloud",
      trait = "com.tencentcloud#action",
      fields = { "service", "version", "action" },
    },
  }
end

local function generate(text, rpc)
  local m, err = gen.model.from_text(text or MODEL, "demo.json")
  if not m then
    return nil, err
  end
  return gen.generate({ model = m, provider = spec(rpc) })
end

t.describe("gen.rpc: provider spec", function()
  t.it("an rpc spec needs no base_url and keeps the rpc key normalized", function()
    local s, err = provider.validate(spec())
    t.truthy(s, err)
    t.eq(s.rpc.method, "POST")
    t.eq(s.rpc.uri, "/")
    t.eq(s.rpc.trait, "com.tencentcloud#action")
  end)

  t.it("refuses unknown keys, bad modules, traits, methods and paths", function()
    local function bad(rpc, pattern)
      local s, err = provider.validate(spec(rpc))
      t.eq(s, nil)
      t.match(err, pattern, true)
    end
    bad({ protocol = "m", trait = "a#b", extra = 1 }, "unknown key extra")
    bad({ protocol = "not a module", trait = "a#b" }, "rpc.protocol must be a module name")
    bad({ protocol = "m", trait = "nohash" }, "rpc.trait must be a trait id")
    bad({ protocol = "m", trait = "a#b", method = "PUT" }, "rpc.method must be POST or GET")
    bad({ protocol = "m", trait = "a#b", uri = "/{x}" }, "rpc.uri must be a path without labels")
    bad({ protocol = "m", trait = "a#b", fields = { "1x" } }, "rpc.fields[1] must be an identifier")
    -- without rpc, base_url is still required
    local plain = fx.provider()
    plain.base_url = nil
    local s, err = provider.validate(plain)
    t.eq(s, nil)
    t.match(err, "base_url", true)
  end)

  t.it("loads providers/tencentcloud.lua", function()
    local s, err = provider.load(t.root .. "/providers/tencentcloud.lua")
    t.truthy(s, err)
    t.eq(s.rpc.protocol, "distilled.protocol.tencentcloud")
  end)
end)

t.describe("gen.rpc: generation", function()
  t.it("an operation without http gets the rpc binding and the trait as op.rpc", function()
    local files, err = generate()
    t.truthy(files, err)
    local svc = fx.load(files["service.lua"], "demo.service")
    local op = svc.ops.describe_things
    t.eq(op.method, "POST")
    t.eq(op.uri, "/")
    t.same(op.rpc, { service = "demo", version = "2020-01-01", action = "DescribeThings" })
    -- a trailing `_` (convert.ts: an object owns the name) is not in the method name
    t.truthy(svc.ops.thing, "thing")
    t.eq(svc.ops.thing.rpc.action, "Thing")
    t.match(files["init.lua"], 'require("distilled.protocol.tencentcloud")', true)
    t.match(files["init.lua"], "options = rpc_protocol.options", true)
    t.match(
      files["README.md"],
      "| `describe_things` | `demo 2020-01-01 DescribeThings` | List things. |",
      true
    )
    t.match(files["README.md"], "| `secret_key` |", true)
    t.match(files["types.lua"], "---@field secret_key? string|distilled.Secret", true)
  end)

  t.it("the generated client signs and sends a call", function()
    local files = generate()
    local svc = fx.load(files["service.lua"], "demo.service")
    package.loaded["demo.service"] = svc
    local Class = fx.load(files["init.lua"], "demo")
    package.loaded["demo.service"] = nil
    local host = require("distilled.testing").host({
      responses = { { status = 200, body = { Response = { TotalCount = 1, RequestId = "r" } } } },
    })
    local c = Class.new({ host = host, secret_id = "AKID", secret_key = "k" })
    local v, err = c:describe_things({ Limit = 1, region = "ap-guangzhou" })
    t.eq(err, nil)
    t.eq(v.TotalCount, 1)
    t.eq(host.requests[1].url, "https://demo.tencentcloudapi.com/")
    t.eq(host.requests[1].headers["x-tc-action"], "DescribeThings")
  end)

  t.it("an operation with neither http nor the trait fails generation early", function()
    local text = string.gsub(
      MODEL,
      '"com.tencentcloud#action": { "service": "demo", "version": "2020%-01%-01", "action": "Thing" }',
      '"smithy.api#documentation": "x"'
    )
    local files, err = generate(text)
    t.eq(files, nil)
    t.match(err, "neither smithy.api#http nor the rpc trait com.tencentcloud#action", true)
  end)

  t.it("a trait without a required field, or with an odd value, fails generation", function()
    local text = string.gsub(MODEL, '"action": "Thing"', '"action": ""')
    local _, err = generate(text)
    t.match(err, "com.tencentcloud#action needs a string action", true)
    local text2 = string.gsub(MODEL, '"action": "Thing"', '"action": "Thi ng"')
    local _, err2 = generate(text2)
    t.match(err2, "is not a plain name", true)
  end)

  t.it("without the rpc key a model without http still fails as before", function()
    local m = gen.model.from_text(MODEL, "demo.json")
    local s = spec()
    s.rpc = nil
    s.base_url = "https://x.test"
    local files, err = gen.generate({ model = m, provider = s })
    t.eq(files, nil)
    t.match(err, "no smithy.api#http trait", true)
  end)
end)

t.describe("clients/tencentcloud (committed)", function()
  t.it("the index lists 263 products and loads one lazily", function()
    local index = require("tencentcloud")
    t.eq(#index.services, 263)
    local Cvm = index.cvm
    t.truthy(Cvm and Cvm.new, "cvm class")
    t.truthy(Cvm.service.ops.describe_instances.rpc, "rpc field")
    local clients = index.new({ secret_id = "a", secret_key = "b" })
    t.truthy(clients.vpc, "vpc client")
  end)
end)
