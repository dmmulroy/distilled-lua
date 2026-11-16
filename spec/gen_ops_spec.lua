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

  t.it("multipart operations fail unless the provider acknowledges them", function()
    local opts = {
      replace = {
        {
          '"uri": "/blobs/{key+}", "code": 204',
          '"uri": "/blobs/{key+}", "code": 204, "contentType": "multipart"',
        },
      },
    }
    local _, err = fx.generate(opts)
    t.match(
      err,
      "ex.api#PutBlob: multipart request bodies are not supported by request.build",
      true
    )
    opts.provider = fx.provider({ allow_unsupported = { "multipart" } })
    local svc = service(opts)
    t.eq(svc.ops.put_blob.content_type, "multipart")
  end)

  t.it("refuses an unsupported http key and method", function()
    local _, err = fx.generate({
      replace = {
        { '"uri": "/names", "code": 200', '"uri": "/names", "code": 200, "server": "x"' },
      },
    })
    t.match(err, "smithy.api#http has unsupported key server", true)
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

  t.it("names colliding with the client's type names fail", function()
    local _, err = fx.generate({
      extra = '"ex.api#Client": { "type": "structure", "members": {} }',
      replace = {
        { '"note": { "target": "smithy.api#String" }', '"note": { "target": "ex.api#Client" }' },
      },
    })
    t.match(err, "ex.api#Client: its type name ex.Client is the client class", true)
  end)
end)
