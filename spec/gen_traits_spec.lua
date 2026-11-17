-- Task 12: model traits the generator used to refuse. smithy.api#http extensions
-- (baseUrl, server, accept, rawDownload), streaming operations, pagination edge cases
-- (Exa's sibling collision, Resend's cursor without outputToken), distilled.errors#bodies
-- on a prelude shape, path placeholders without a label member, prelude outputs.
local t = require("spec.harness")
local fx = require("verify.lib.gen_fixture")
local S = require("distilled.schema")
local testing = require("distilled.testing")
local rest = require("distilled.protocol.rest")

local function generate(opts)
  local files, err, plan = fx.generate(opts)
  if not files then
    t.fail("generation failed: " .. tostring(err))
  end
  return files, plan
end

local function service(opts)
  local files, plan = generate(opts)
  return fx.load(files["service.lua"], "ex.service"), files, plan
end

-- the generated client class, loaded with the real runtime
local function client_class(files)
  local svc = fx.load(files["service.lua"], "ex.service")
  return fx.load(files["init.lua"], "ex", { ["ex.service"] = svc }), svc
end

local function new_client(files, responses, options)
  local class = client_class(files)
  local host = testing.host({ responses = responses or {} })
  local opts = { host = host, api_key = "k", retry = "none" }
  for k, v in pairs(options or {}) do
    opts[k] = v
  end
  return class.new(opts), host
end

local GET_THING_HTTP = '"method": "GET", "uri": "/things/{thing_id}", "code": 200'
local LIST_NAMES_HTTP = '"method": "GET", "uri": "/names", "code": 200'
local GET_BLOB_HTTP = '"method": "GET", "uri": "/blobs/{key+}", "code": 200'

local function http_extra(op_http, extra)
  return { op_http, op_http .. ", " .. extra }
end

---------------------------------------------------------------------------------------
-- smithy.api#http extensions
---------------------------------------------------------------------------------------

local HOSTS = {
  replace = {
    http_extra(GET_THING_HTTP, '"baseUrl": "https://{region}.other.test"'),
    http_extra(LIST_NAMES_HTTP, '"server": "inference"'),
    http_extra(
      GET_BLOB_HTTP,
      '"accept": "application/vnd.ex.2024-05-30+json", "rawDownload": true'
    ),
  },
}

t.describe("gen: smithy.api#http baseUrl, server, accept, rawDownload", function()
  t.it("become op.base_url, op.server, op.accept, op.raw_download", function()
    local svc = service(HOSTS)
    t.eq(svc.ops.get_thing.base_url, "https://{region}.other.test")
    t.eq(svc.ops.list_names.server, "inference")
    t.eq(svc.ops.get_blob.accept, "application/vnd.ex.2024-05-30+json")
    t.eq(svc.ops.get_blob.raw_download, true)
    t.eq(svc.ops.list_things.base_url, nil)
    t.eq(svc.ops.list_things.server, nil)
    t.eq(svc.ops.list_things.accept, nil)
    t.eq(svc.ops.list_things.raw_download, nil)
  end)

  t.it("the client gets an option per server and per base URL variable", function()
    local files = generate(HOSTS)
    t.match(
      files["init.lua"],
      'base_url = rest.route_base_url("base_url", { default = "https://api.example.test/v1" }),',
      true
    )
    t.match(files["init.lua"], "inference_base_url = {},", true)
    t.match(files["init.lua"], "region = {},", true)
  end)

  t.it("a model without them keeps the plain base_url function", function()
    local files = generate()
    t.no_match(files["init.lua"], "route_base_url", true)
    t.match(files["init.lua"], "return creds.base_url", true)
  end)

  t.it("bad values fail generation", function()
    local cases = {
      { '"accept": "json"', "accept must be a media type" },
      { '"server": "Inference"', "server must be a lower-case host name" },
      { '"server": "https://x.test"', "server must be a lower-case host name" },
      { '"baseUrl": "ftp://x.test"', "baseUrl must be an http(s) URL" },
      { '"baseUrl": "https://x.test/"', "baseUrl must not end with /" },
      { '"baseUrl": "https://{re gion}.x.test"', "bad template variable {re gion}" },
      { '"baseUrl": "https://{host}.x.test"', "variable {host} is a common client option" },
      { '"baseUrl": "https://x.test", "server": "inference"', "has both baseUrl and server" },
      { '"rawDownload": "yes"', "rawDownload must be a boolean" },
    }
    for _, c in ipairs(cases) do
      local _, err = fx.generate({ replace = { http_extra(LIST_NAMES_HTTP, c[1]) } })
      t.match(err, "ex.api#ListNames: smithy.api#http", true)
      t.match(err, c[2], true)
    end
  end)
end)

t.describe("runtime: per-operation hosts and Accept through a generated client", function()
  local files = generate(HOSTS)
  local OK = { status = 200, body = { thing = { id = "1" } } }

  t.it("a base URL with {region} is filled from the region option", function()
    local c, host = new_client(files, { OK }, { region = "eu1" })
    local v, err = c:get_thing({ thing_id = "1" })
    t.eq(err, nil)
    t.eq(v.thing.id, "1")
    t.eq(host.requests[1].url, "https://eu1.other.test/things/1")
    t.eq(host.requests[1].headers["authorization"], "Bearer k")
  end)

  t.it(
    "an unset or non-host variable is a ConfigError naming the option; nothing is sent",
    function()
      local c, host = new_client(files, {})
      local _, err = c:get_thing({ thing_id = "1" })
      t.eq(err.tag, "ConfigError")
      t.eq(err.key, "region")
      t.eq(#host.requests, 0)
      c = new_client(files, {}, { region = "evil.test/x?" })
      _, err = c:get_thing({ thing_id = "1" })
      t.eq(err.key, "region")
    end
  )

  t.it("a server op goes to <server>_base_url, and fails without it", function()
    local c, host = new_client(
      files,
      { { status = 200, body = { "a" } } },
      { inference_base_url = "https://inference.test" }
    )
    local v, err = c:list_names({})
    t.eq(err, nil)
    t.same(v, { "a" })
    t.eq(host.requests[1].url, "https://inference.test/names")
    c, host = new_client(files, {}, { base_url = "https://main.test" })
    local _, err2 = c:list_names({})
    t.eq(err2.tag, "ConfigError")
    t.eq(err2.key, "inference_base_url")
    t.match(err2.message, "runs on server inference", true)
    t.eq(#host.requests, 0)
  end)

  t.it("other operations stay on the base_url option", function()
    local c, host = new_client(files, { { status = 200, body = { things = {} } } }, {
      base_url = "https://main.test",
    })
    t.truthy(c:list_things({}))
    t.eq(host.requests[1].url, "https://main.test/things")
    t.eq(host.requests[1].headers["accept"], "application/json")
  end)

  t.it("op.accept replaces the default Accept", function()
    local c, host = new_client(files, { { status = 200, body = "bytes" } })
    t.eq(c:get_blob({ key = "a/b" }), "bytes")
    t.eq(host.requests[1].headers["accept"], "application/vnd.ex.2024-05-30+json")
  end)
end)

t.describe("rest.route_base_url", function()
  local f = rest.route_base_url("base_url", {
    default = "https://api.main.test",
    servers = { actions = "actions_url" },
  })

  t.it("no route host: the base_url option", function()
    t.eq(f({ base_url = "https://o.test" }, { uri = "/x", method = "GET" }), "https://o.test")
  end)

  t.it("an op base URL equal to the provider default still follows the option", function()
    -- ScalewayProtocol baseUrlFor: SCW_API_URL moves api.scaleway.com, not api.scaleway.ai
    t.eq(
      f({ base_url = "https://o.test" }, { base_url = "https://api.main.test" }),
      "https://o.test"
    )
    t.eq(
      f({ base_url = "https://o.test" }, { base_url = "https://api.other.test" }),
      "https://api.other.test"
    )
  end)

  t.it("servers map a server to an option; the default is <server>_base_url", function()
    t.eq(f({ actions_url = "https://a.test" }, { server = "actions" }), "https://a.test")
    t.eq(f({ inference_base_url = "https://i.test" }, { server = "inference" }), "https://i.test")
    local v, err = f({ actions_base_url = "https://a.test" }, { server = "actions" })
    t.eq(v, nil)
    t.eq(err.key, "actions_url")
  end)

  t.it("variables accept numbers and secrets; values outside a host name are refused", function()
    local route = { base_url = "https://{a}.{b}.x.test" }
    t.eq(f({ a = 1, b = require("distilled.secret")("eu-1_x") }, route), "https://1.eu-1_x.x.test")
    local _, err = f({ a = "x", b = "y/z" }, route)
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "b")
    t.no_match(err.message, "y/z", true)
  end)

  t.it("misuse raises", function()
    t.raises(function()
      rest.route_base_url(nil)
    end, "option must be")
  end)
end)

---------------------------------------------------------------------------------------
-- streaming
---------------------------------------------------------------------------------------

local function streaming(trait)
  return {
    replace = {
      {
        '"smithy.api#documentation": "Get a thing\\n\\nReturns the thing.",',
        '"smithy.api#documentation": "Get a thing\\n\\nReturns the thing.", "' .. trait .. '": {},',
      },
    },
  }
end

t.describe('gen: streaming operations (allow_unsupported = { "streaming" })', function()
  local ALLOW = fx.provider({ allow_unsupported = { "streaming" } })

  for _, trait in ipairs({
    "com.distilled.grpc#serverStreaming",
    "com.distilled.grpc#clientStreaming",
  }) do
    t.it(trait .. " fails generation unless the provider acknowledges it", function()
      local _, err = fx.generate(streaming(trait))
      t.match(err, "ex.api#GetThing: " .. trait .. ": distilled-lua cannot stream yet", true)
      t.match(err, 'allow_unsupported = { "streaming" }', true)
    end)

    t.it(trait .. " with it: op.unsupported, and every call fails with SdkError", function()
      local opts = streaming(trait)
      opts.provider = ALLOW
      local files = generate(opts)
      local svc = fx.load(files["service.lua"], "ex.service")
      t.eq(svc.ops.get_thing.unsupported, "streaming")
      t.eq(svc.ops.list_things.unsupported, nil)
      local c, host = new_client(files, {})
      local v, err = c:get_thing({ thing_id = "1" })
      t.eq(v, nil)
      t.eq(err.tag, "SdkError")
      t.match(err.message, "cannot perform streaming operations", true)
      t.eq(#host.requests, 0)
    end)
  end

  t.it("streamWhen: needs the acknowledgement too; then the plain call is emitted", function()
    local trait = "com.distilled.openapi#streamWhen"
    local _, err = fx.generate(streaming(trait))
    t.match(err, "emit its plain call", true)
    local opts = streaming(trait)
    opts.provider = ALLOW
    local files = generate(opts)
    local svc = fx.load(files["service.lua"], "ex.service")
    t.eq(svc.ops.get_thing.unsupported, nil)
    local c, host = new_client(files, { { status = 200, body = { thing = { id = "7" } } } })
    local v = c:get_thing({ thing_id = "7" })
    t.eq(v.thing.id, "7")
    t.eq(#host.requests, 1)
  end)
end)

---------------------------------------------------------------------------------------
-- pagination
---------------------------------------------------------------------------------------

-- ListThingsItems: a real (non-paginated) operation named like ListThings's items method
local ITEMS_OP = [["ex.api#ListThingsItems": {
  "type": "operation",
  "input": { "target": "ex.api#ListThingsItemsRequest" },
  "output": { "target": "ex.api#ListThingsItemsResponse" },
  "traits": { "smithy.api#http": { "method": "GET", "uri": "/thing-items", "code": 200 } }
},
"ex.api#ListThingsItemsRequest": { "type": "structure", "members": {} },
"ex.api#ListThingsItemsResponse": { "type": "structure", "members": { "n": { "target": "smithy.api#Integer" } } }]]

t.describe("gen: a _pages/_items sibling that would take an operation's name (Exa)", function()
  local files = generate({ extra = ITEMS_OP })
  local svc = fx.load(files["service.lua"], "ex.service")

  t.it("the operation keeps its name; the sibling becomes _all_items", function()
    t.eq(svc.ops.list_things_items.name, "ListThingsItems")
    t.same(svc.ops.list_things.pagination_methods, { items = "list_things_all_items" })
    t.eq(svc.ops.get_thing.pagination_methods, nil)
  end)

  t.it("the client has both, and they do what they say", function()
    local c, host = new_client(files, {
      { status = 200, body = { n = 3 } },
      { status = 200, body = { things = { { id = "a" }, { id = "b" } } } },
    })
    t.eq(c:list_things_items({}).n, 3)
    t.eq(host.requests[1].url, "https://api.example.test/v1/thing-items")
    local all = c:list_things_all_items({}):collect()
    t.eq(#all, 2)
    t.eq(all[2].id, "b")
    t.eq(type(c.list_things_pages), "function")
  end)

  t.it("types.lua and the README name the renamed sibling", function()
    t.match(files["types.lua"], "function Client:list_things_all_items(input) end", true)
    t.match(files["types.lua"], "function Client:list_things_items(input) end", true)
    t.match(files["README.md"], "(+ `list_things_pages`, `list_things_all_items`)", true)
  end)
end)

t.describe("gen: cursor pagination without outputToken (Resend)", function()
  local RESEND = '{ "mode": "cursor", "inputToken": "cursor", "items": "things", '
    .. '"hasNextPage": "more", "pageSize": "limit" }'
  local opts = {
    replace = {
      {
        '"smithy.api#paginated": { "mode": "cursor", "inputToken": "cursor", '
          .. '"outputToken": "pagination.next", "items": "things", "pageSize": "limit" }',
        '"smithy.api#paginated": ' .. RESEND,
      },
    },
  }

  t.it("is emitted as a plain operation, with a warning", function()
    local m = assert(fx.model(opts))
    local files, err = require("distilled.gen").generate({ model = m, provider = fx.provider() })
    t.eq(err, nil)
    local svc = fx.load(files["service.lua"], "ex.service")
    t.eq(svc.ops.list_things.pagination, nil)
    t.no_match(files["types.lua"], "list_things_items", true)
    local found = false
    for _, w in ipairs(m.warnings) do
      found = found
        or string.find(w, "ex.api#ListThings: cursor pagination without outputToken", 1, true)
          ~= nil
    end
    t.truthy(found, "warning")
    local c = new_client(files, {})
    t.eq(c.list_things_items, nil)
  end)

  t.it("without hasNextPage it still fails (Distilled's assertPaginationFields)", function()
    local _, err = fx.generate({
      replace = {
        {
          '"outputToken": "pagination.next", "items": "things"',
          '"items": "things"',
        },
      },
    })
    t.match(err, "cursor pagination needs outputToken", true)
  end)
end)

---------------------------------------------------------------------------------------
-- distilled.errors#bodies, placeholders, prelude outputs
---------------------------------------------------------------------------------------

local function bodies(list)
  return {
    replace = {
      {
        '"smithy.api#documentation": "Get a thing\\n\\nReturns the thing.",',
        '"smithy.api#documentation": "Get a thing\\n\\nReturns the thing.", "distilled.errors#bodies": '
          .. list
          .. ",",
      },
    },
  }
end

t.describe("gen: distilled.errors#bodies with a prelude target (coinflow)", function()
  t.it("a smithy.api#String or #Double body is skipped, as Distilled does", function()
    local _, plan = generate(
      bodies(
        '[{ "status": 404, "target": "smithy.api#String" }, '
          .. '{ "status": 404, "target": "smithy.api#Double" }]'
      )
    )
    for _, d in ipairs(plan.errors) do
      t.same(d.bodies, {}, d.tag)
    end
  end)

  t.it("a model shape next to it is still documented", function()
    local _, plan = generate(
      bodies(
        '[{ "status": 404, "target": "smithy.api#String" }, '
          .. '{ "status": 404, "target": "ex.api#Meta" }]'
      )
    )
    local by_tag = {}
    for _, d in ipairs(plan.errors) do
      by_tag[d.tag] = d
    end
    t.same(by_tag.NotFound.bodies, { "ex.api#Meta" })
  end)

  t.it("a dangling non-prelude target still fails", function()
    local _, err = fx.generate(bodies('[{ "status": 404, "target": "ex.api#Nope" }]'))
    t.match(err, "distilled.errors#bodies target ex.api#Nope is not a shape", true)
  end)
end)

t.describe("gen: a path placeholder with no label member (proxmox {url_seq})", function()
  local opts = {
    replace = {
      {
        '"uri": "/things/{thing_id}", "code": 200',
        '"uri": "/things/{thing_id}/parts/{url_seq}", "code": 200',
      },
    },
  }

  t.it("the operation is emitted, with a warning", function()
    local m = assert(fx.model(opts))
    local files, err = require("distilled.gen").generate({ model = m, provider = fx.provider() })
    t.eq(err, nil)
    t.match(
      table.concat(m.warnings, "\n"),
      "ex.api#GetThing: {url_seq} in /things/{thing_id}/parts/{url_seq} has no label member",
      true
    )
    local c, host = new_client(files, { { status = 200, body = { thing = { id = "1" } } } })
    t.truthy(c:get_thing({ thing_id = "1", url_seq = "9" }))
    t.eq(host.requests[1].url, "https://api.example.test/v1/things/1/parts/9")
    local _, cerr = c:get_thing({ thing_id = "1" })
    t.eq(cerr.tag, "InvalidInput")
    t.eq(cerr.member, "url_seq")
  end)
end)

t.describe("gen: a prelude output other than Unit (Stripe's smithy.api#Document)", function()
  t.it("the body is the value", function()
    local svc, files = service({
      replace = {
        {
          '"output": { "target": "ex.api#ListNamesResponse" }',
          '"output": { "target": "smithy.api#Document" }',
        },
      },
    })
    t.eq(svc.ops.list_names.output_raw, true)
    t.eq(svc.ops.list_names.output, S.unknown)
    local c = new_client(files, { { status = 200, body = { any = { "thing" } } } })
    local v = c:list_names({})
    t.eq(v.any[1], "thing")
  end)
end)

t.describe("gen: a Unit output whose synthesized name is an operation (Mailchimp)", function()
  -- Ping has no output, so it gets PingResponse, which is also an operation's name
  local PING = [["ex.api#Ping": {
  "type": "operation",
  "traits": { "smithy.api#http": { "method": "GET", "uri": "/ping", "code": 200 } }
},
"ex.api#PingResponse": {
  "type": "operation",
  "output": { "target": "ex.api#PingResponseOut" },
  "traits": { "smithy.api#http": { "method": "GET", "uri": "/ping-response", "code": 200 } }
},
"ex.api#PingResponseOut": { "type": "structure", "members": { "ok": { "target": "smithy.api#Boolean" } } }]]

  t.it("both operations are emitted and the output resolves to an empty structure", function()
    local svc = service({ extra = PING })
    local out = S.resolve(svc.ops.ping.output, svc.shapes)
    t.eq(out.t, "struct")
    t.eq(#out.members, 0)
    t.eq(svc.ops.ping_response.name, "PingResponse")
    t.eq(S.resolve(svc.ops.ping_response.output, svc.shapes).t, "struct")
  end)

  t.it("a non-empty structure under that name is a problem, not overwritten", function()
    local _, err = fx.generate({
      extra = [["ex.api#Ping": {
  "type": "operation",
  "traits": { "smithy.api#http": { "method": "GET", "uri": "/ping", "code": 200 } }
},
"ex.api#PingResponse": { "type": "structure", "members": { "ok": { "target": "smithy.api#Boolean" } } }]],
    })
    t.match(err, "ex.api#Ping: its Unit input or output needs the name ex.api#PingResponse", true)
  end)
end)
