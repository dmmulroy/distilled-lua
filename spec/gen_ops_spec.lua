local t = require("spec.harness")
local fx = require("verify.lib.gen_fixture")
local S = require("distilled.schema")

local function service(opts)
  local files, err, plan = fx.generate(opts)
  if not files then
    t.fail("generation failed: " .. tostring(err))
  end
  return fx.load(files["service.lua"], "ex.service"), files, plan
end

local PAGINATED = '"smithy.api#paginated": { "mode": "cursor", "inputToken": "cursor", '
  .. '"outputToken": "pagination.next", "items": "things", "pageSize": "limit" }'

local function with_pagination(trait)
  return { replace = { { PAGINATED, '"smithy.api#paginated": ' .. trait } } }
end

t.describe("gen.ops: descriptors", function()
  local svc = service()

  t.it("carries method, uri, code, input, output and errors", function()
    local op = svc.ops.get_thing
    t.eq(op.name, "GetThing")
    t.eq(op.method, "GET")
    t.eq(op.uri, "/things/{thing_id}")
    t.eq(op.code, 200)
    t.same(op.input, { t = "ref", name = "GetThingRequest" })
    t.same(op.output, { t = "ref", name = "ThingResponse" })
    t.eq(op.output_raw, nil)
    t.eq(svc.ops.put_blob.code, 204)
  end)

  t.it("a rawResponse output is the member's value (output_raw)", function()
    t.same(svc.ops.list_names.output, { t = "ref", name = "TagList" })
    t.eq(svc.ops.list_names.output_raw, true)
    t.eq(svc.ops.get_blob.output, S.blob)
    t.eq(svc.ops.get_blob.output_raw, true)
  end)

  t.it("translates the pagination trait", function()
    t.same(svc.ops.list_things.pagination, {
      mode = "cursor",
      input_token = "cursor",
      output_token = "pagination.next",
      items = "things",
      page_size = "limit",
    })
    t.eq(svc.ops.get_thing.pagination, nil)
  end)

  t.it("every op input is a registry struct", function()
    for name, op in pairs(svc.ops) do
      local node = S.resolve(op.input, svc.shapes)
      t.eq(node and node.t, "struct", name)
    end
  end)
end)

t.describe("gen.ops: pagination validation (Distilled pagination.ts)", function()
  t.it("a trait missing a field its mode reads fails generation", function()
    local _, err = fx.generate(
      with_pagination('{ "mode": "cursor", "inputToken": "cursor", "items": "things" }')
    )
    t.match(err, "ex.api#ListThings: cursor pagination needs outputToken", true)
    _, err = fx.generate(
      with_pagination('{ "mode": "keyset", "inputToken": "cursor", "outputToken": "id" }')
    )
    t.match(err, "keyset pagination needs items", true)
    _, err = fx.generate(with_pagination('{ "outputToken": "pagination.next", "items": "things" }'))
    t.match(err, "token pagination needs inputToken", true)
  end)

  t.it("link mode needs only inputToken; single needs nothing", function()
    local svc =
      service(with_pagination('{ "mode": "link", "inputToken": "cursor", "items": "things" }'))
    t.eq(svc.ops.list_things.pagination.mode, "link")
    svc = service(with_pagination('{ "mode": "single", "items": "things" }'))
    t.eq(svc.ops.list_things.pagination.mode, "single")
  end)

  t.it("a token or items path that is not a member fails generation", function()
    local _, err = fx.generate(
      with_pagination(
        '{ "mode": "cursor", "inputToken": "page", "outputToken": "pagination.next", "items": "things" }'
      )
    )
    t.match(err, "pagination inputToken page is not an input member", true)
    _, err = fx.generate(
      with_pagination(
        '{ "mode": "cursor", "inputToken": "cursor", "outputToken": "pagination.next", "items": "rows" }'
      )
    )
    t.match(err, "pagination items rows is not an output member", true)
    _, err = fx.generate(
      with_pagination(
        '{ "mode": "cursor", "inputToken": "cursor", "outputToken": "x", "items": "things", "pageSize": "size" }'
      )
    )
    t.match(err, "pagination pageSize size is not an input member", true)
  end)

  t.it("the items fallback applies when the trait has no items", function()
    local _, err = fx.generate(
      with_pagination(
        '{ "mode": "cursor", "inputToken": "cursor", "outputToken": "pagination.next" }'
      )
    )
    t.match(err, "pagination items items is not an output member", true)
    local svc = service({
      replace = with_pagination(
        '{ "mode": "cursor", "inputToken": "cursor", "outputToken": "pagination.next" }'
      ).replace,
      provider = fx.provider({ pagination = { items_fallback = "things" } }),
    })
    t.eq(svc.ops.list_things.pagination.items, "things")
  end)

  t.it("unknown modes and keys fail", function()
    local _, err = fx.generate(with_pagination('{ "mode": "offset", "inputToken": "cursor" }'))
    t.match(err, "mode offset is not known", true)
    _, err = fx.generate(
      with_pagination(
        '{ "mode": "cursor", "inputToken": "cursor", "outputToken": "n", "items": "things", "step": 1 }'
      )
    )
    t.match(err, "smithy.api#paginated has unknown key step", true)
  end)
end)

t.describe("gen.ops: retry policy trait (retryPolicyOf)", function()
  local function with_retry(svc_trait, op_trait)
    local replace = {}
    if svc_trait then
      replace[#replace + 1] = {
        '"smithy.api#title": "Example API",',
        '"smithy.api#title": "Example API", "distilled.retry#policy": ' .. svc_trait .. ",",
      }
    end
    if op_trait then
      replace[#replace + 1] = {
        '"smithy.api#http": { "method": "GET", "uri": "/names", "code": 200 },',
        '"smithy.api#http": { "method": "GET", "uri": "/names", "code": 200 }, "distilled.retry#policy": '
          .. op_trait
          .. ",",
      }
    end
    return { replace = replace }
  end

  t.it("merges the operation's numbers over the service's, in snake_case", function()
    local svc = service(
      with_retry('{ "maxAttempts": 3, "baseMs": 100 }', '{ "baseMs": 250, "longPoll": true }')
    )
    t.same(svc.ops.list_names.retry, { max_attempts = 3, base_ms = 250, long_poll = true })
    t.same(svc.ops.get_thing.retry, { max_attempts = 3, base_ms = 100 })
  end)

  t.it("no trait, no retry", function()
    local svc = service()
    t.eq(svc.ops.get_thing.retry, nil)
  end)

  t.it("rejects unknown keys and bad numbers", function()
    local _, err = fx.generate(with_retry(nil, '{ "retries": 3 }'))
    t.match(err, "ex.api#ListNames: distilled.retry#policy has unknown key retries", true)
    _, err = fx.generate(with_retry(nil, '{ "maxAttempts": 0 }'))
    t.match(err, "maxAttempts must be a whole number", true)
    _, err = fx.generate(with_retry(nil, '{ "factor": 0.5 }'))
    t.match(err, "factor must be a number of at least 1", true)
    _, err = fx.generate(with_retry('{ "longPoll": "yes" }'))
    t.match(err, "service: distilled.retry#policy.longPoll must be a boolean", true)
  end)
end)

t.describe("gen.ops: telemetry", function()
  t.it("hoists the shared rules into service.telemetry and keeps spans minimal", function()
    local svc = service()
    t.same(svc.telemetry, {
      system = "ex-api",
      prefix = "Ex",
      service = "Ex",
      labels = "ex",
      propagate = "w3c",
      response_headers = {
        { header = "x-request-id", name = "http.response.header.x-request-id", transform = "list" },
      },
    })
    t.eq(svc.ops.get_thing.span, "GetThing")
    t.eq(svc.ops.list_things.span, "ListThings")
    -- a label with no attribute rule drops the derived one (Distilled emits `key: []`)
    t.same(svc.ops.get_blob.span, { op = "GetBlob", input = { key = {} } })
  end)

  t.it("states what differs from the derived rules", function()
    local svc = service({
      replace = {
        {
          '{ "name": "Ex.ListNames", "method": "Ex/ListNames", "attributes": { "url.template": "/names" } }',
          '{ "name": "Custom.Names", "method": "Ex/ListNames", "kind": "producer", "attributes": { "url.template": "/names/{x}", "extra.flag": true } }',
        },
      },
    })
    t.same(svc.ops.list_names.span, {
      op = "ListNames",
      name = "Custom.Names",
      kind = "producer",
      attributes = { ["url.template"] = "/names/{x}", ["extra.flag"] = true },
    })
  end)

  t.it("--no-telemetry leaves span and service telemetry out", function()
    local svc, files = service({ telemetry = false })
    t.eq(svc.telemetry, nil)
    for _, op in pairs(svc.ops) do
      t.eq(op.span, nil)
    end
    t.match(files["service.lua"], "Telemetry: off (--no-telemetry).", true)
  end)

  t.it("unsupported telemetry features fail, pointing at --no-telemetry", function()
    local _, err = fx.generate({
      replace = { { '"name": "Ex.ListNames",', '"name": "Ex.ListNames", "nameTemplate": "x",' } },
    })
    t.match(
      err,
      "nameTemplate (span name templates) is not supported; generate with --no-telemetry",
      true
    )
    local svc = service({
      telemetry = false,
      replace = { { '"name": "Ex.ListNames",', '"name": "Ex.ListNames", "nameTemplate": "x",' } },
    })
    t.eq(svc.ops.list_names.span, nil)
  end)
end)

t.describe("gen.ops: http trait and selection", function()
  t.it("--ops keeps the named operations and what they reach", function()
    local svc, _, plan = service({ ops = { "get_blob", "ListNames" } })
    local names = {}
    for name in pairs(svc.ops) do
      names[#names + 1] = name
    end
    table.sort(names)
    t.same(names, { "get_blob", "list_names" })
    t.eq(svc.shapes.Thing, nil)
    t.truthy(svc.shapes.TagList)
    t.eq(svc.errors.NotFound ~= nil, true)
    t.eq(#plan.ops, 2)
  end)

  t.it("--ops with an unknown name suggests the nearest", function()
    local files, err = fx.generate({ ops = { "get_thingz" } })
    t.eq(files, nil)
    t.match(err, "unknown operation get_thingz; nearest: get_thing", true)
  end)

  -- task 08: request.build encodes multipart, so no acknowledgement is needed, and a
  -- Blob member of a multipart input is typed as a file part
  t.it("multipart operations generate without allow_unsupported; blobs are files", function()
    local opts = {
      replace = {
        {
          '"uri": "/blobs/{key+}", "code": 204',
          '"uri": "/blobs/{key+}", "code": 204, "contentType": "multipart"',
        },
      },
    }
    local svc, files = service(opts)
    local _, plain = service()
    t.eq(svc.ops.put_blob.content_type, "multipart")
    t.match(files["types.lua"], "---@class distilled.File\n", true)
    t.match(files["types.lua"], "---@field body distilled.File|string", true)
    -- task 09: the docs name the constructor distilled.file{...}
    t.match(files["types.lua"], "`distilled.file{ data, filename?, content_type? }`", true)
    t.no_match(files["types.lua"], "distilled.multipart", true)
    t.match(files["README.md"], "distilled.file({", true)
    t.no_match(plain["README.md"], "distilled.file", true)
    -- a non-multipart blob member stays a string
    t.match(plain["types.lua"], "---@field body string", true)
    t.no_match(plain["types.lua"], "---@field body distilled.File", true)
  end)

  t.it("refuses an unsupported http key and method", function()
    local _, err = fx.generate({
      replace = {
        { '"uri": "/names", "code": 200', '"uri": "/names", "code": 200, "frobnicate": "x"' },
      },
    })
    t.match(err, "smithy.api#http has unsupported key frobnicate", true)
    -- apiVersion is Azure's (task 20): only the Azure protocol may carry it
    _, err = fx.generate({
      replace = {
        { '"uri": "/names", "code": 200', '"uri": "/names", "code": 200, "apiVersion": "x"' },
      },
    })
    t.match(err, "api-version x needs the Azure protocol", true)
    _, err = fx.generate({
      replace = { { '"method": "GET", "uri": "/names"', '"method": "TRACE", "uri": "/names"' } },
    })
    t.match(err, "method TRACE is not supported", true)
  end)

  t.it("bodyMediaType becomes op.body_media_type", function()
    local svc = service({
      replace = {
        {
          '"uri": "/blobs/{key+}", "code": 204',
          '"uri": "/blobs/{key+}", "code": 204, "bodyMediaType": "application/zip"',
        },
      },
    })
    t.eq(svc.ops.put_blob.body_media_type, "application/zip")
  end)

  -- Task 11: Distilled has no such rule (its error classes are the shapes' own names and
  -- there is no Client type), so ours is documented in naming.type_names: a shape whose
  -- LuaLS type name the client takes (Client, Options, Module, <Tag>Error) is typed
  -- <Name>Shape (then Shape2, ...). Registry keys and S.ref names do not change.
  local function count(text, plain)
    local n, at = 0, 1
    while true do
      local s, e = string.find(text, plain, at, true)
      if not s then
        return n
      end
      n, at = n + 1, e + 1
    end
  end

  t.it("shapes named like the client's types get the Shape suffix in types.lua", function()
    local files, err, plan = fx.generate({
      extra = '"ex.api#Client": { "type": "structure", "members": { "id": { "target": "smithy.api#String" } } },'
        .. ' "ex.api#Module": { "type": "structure", "members": {} },'
        .. ' "ex.api#Options": { "type": "list", "member": { "target": "ex.api#Client" } },'
        .. ' "ex.api#ModuleShape": { "type": "structure", "members": {} },'
        .. ' "ex.api#NotFoundError": { "type": "structure", "members": { "m": { "target": "ex.api#Module" } } }',
      replace = {
        {
          '"note": { "target": "smithy.api#String" }',
          '"note": { "target": "ex.api#Client" }, "opts": { "target": "ex.api#Options" },'
            .. ' "nf": { "target": "ex.api#NotFoundError" }, "ms": { "target": "ex.api#ModuleShape" }',
        },
      },
    })
    t.eq(err, nil)
    local ty = files["types.lua"]
    t.match(ty, "---@class ex.ClientShape\n---@field id? string\n", true)
    t.match(ty, "---@alias ex.OptionsShape ex.ClientShape[]\n", true)
    t.match(ty, "---@class ex.ModuleShape2\n", true)
    t.match(ty, "---@class ex.ModuleShape\n", true)
    t.match(ty, "---@class ex.NotFoundErrorShape\n---@field m? ex.ModuleShape2\n", true)
    t.match(ty, "---@field note? ex.ClientShape\n", true)
    t.match(ty, "---@field nf? ex.NotFoundErrorShape\n", true)
    t.match(ty, "---@field ms? ex.ModuleShape\n", true)
    -- the client's own types and the error class are untouched, and declared once
    t.match(ty, '---@class ex.NotFoundError: distilled.Error\n---@field tag "NotFound"\n', true)
    t.eq(count(ty, "---@class ex.Client\n"), 1)
    t.eq(count(ty, "---@class ex.Module\n"), 1)
    t.eq(count(ty, "---@class ex.Options\n"), 1)
    t.eq(count(ty, "---@class ex.NotFoundError:"), 1)
    t.eq(count(ty, "---@class ex.NotFoundError\n"), 0)
    -- the registry keeps the model's names
    local svc = fx.load(files["service.lua"], "ex.service")
    t.eq(svc.shapes.Client.name, "Client")
    t.same(svc.shapes.Options, { t = "list", item = { t = "ref", name = "Client" } })
    t.eq(svc.shapes.NotFoundError.t, "struct")
    t.eq(plan.ctx.type_names["ex.api#Client"], "ClientShape")
    t.eq(plan.ctx.type_names["ex.api#Thing"], nil)
    t.truthy(require("distilled.compat").load(ty, "=types"))
  end)
end)

-- Task 11: a rawResponse member with the nullable trait (anthropic, discord, polymarket,
-- tailscale, vercel). Distilled emits `S.NullOr(target)` as the bare-payload output; an
-- empty body still decodes like the target's (resolveNode collapses NullOr: `""` for a
-- string, `{}` otherwise) and a JSON `null` body is the value null, in strict mode too
-- (protocol-rest.test.ts "a 200 response whose body is JSON null returns null").
t.describe("gen.ops: nullable rawResponse output", function()
  local json = require("distilled.json")
  local testing = require("distilled.testing")

  local NULLABLE_RAW = {
    '"body": { "target": "ex.api#TagList", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {} } }',
    '"body": { "target": "ex.api#TagList", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {}, "com.distilled.openapi#nullable": {} } }',
  }
  local NULLABLE_TEXT = {
    '"body": { "target": "smithy.api#Blob", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {} } }',
    '"body": { "target": "smithy.api#String", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {}, "com.distilled.openapi#nullable": {} } }',
  }
  local svc, files = service({ replace = { NULLABLE_RAW, NULLABLE_TEXT } })

  local function client(responses, validation)
    local class = fx.load(files["init.lua"], "ex", { ["ex.service"] = svc })
    return class.new({
      api_key = "k",
      host = testing.host({ responses = responses }),
      validation = validation,
    })
  end

  t.it("the output is the target's node marked nullable, still output_raw", function()
    t.same(svc.ops.list_names.output, { t = "ref", name = "TagList", nullable = true })
    t.eq(svc.ops.list_names.output_raw, true)
    t.same(svc.ops.get_blob.output, { t = "string", nullable = true })
    t.match(files["service.lua"], 'output = S.nullable(S.ref("TagList"))', true)
  end)

  t.it("types.lua returns the target or distilled.Null", function()
    t.match(
      files["types.lua"],
      "---@return (ex.TagList|distilled.Null)? value\n---@return distilled.Error? err\n"
        .. "function Client:list_names(input) end",
      true
    )
  end)

  t.it("a JSON null body is json.null, in strict mode too", function()
    for _, mode in ipairs({ "lenient", "additional", "strict" }) do
      local c = client({ { status = 200, body = "null" } }, mode)
      local v, err = c:list_names()
      t.eq(err, nil, mode)
      t.eq(v, json.null, mode)
    end
  end)

  t.it("a list body is the list; a wrong body still fails strict validation", function()
    local v, err = client({ { status = 200, body = '["a","b"]' } }, "strict"):list_names()
    t.eq(err, nil)
    t.same(v, { "a", "b" })
    local _, err2 = client({ { status = 200, body = '{"a":1}' } }, "strict"):list_names()
    t.eq(err2 and err2.tag, "ExParseError")
  end)

  t.it('an empty body decodes as for the target: {} (or "" for a string)', function()
    local v, err = client({ { status = 200, body = "" } }):list_names()
    t.eq(err, nil)
    t.truthy(json.is_object(v))
    t.eq(next(v), nil)
    local _, err2 = client({ { status = 204, body = "" } }, "strict"):list_names()
    t.eq(err2 and err2.tag, "ExParseError")
    local s, err3 = client({ { status = 200, body = "" } }, "strict"):get_blob({ key = "k" })
    t.eq(err3, nil)
    t.eq(s, "")
  end)
end)
