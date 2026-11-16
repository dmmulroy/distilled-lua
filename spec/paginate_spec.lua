-- Pagination: every mode and stop condition of Distilled's pagination.ts, the iterator
-- object, and the traversal span. Ports pagination.test.ts (cursor scenarios, nextLink,
-- keyset) and the Link-header cases of protocol-rest.test.ts.
local t = require("spec.harness")
local paginate = require("distilled.paginate")
local errors = require("distilled.errors")
local json = require("distilled.json")
local trace = require("distilled.trace")
local expect = require("distilled.trace.expect")
local Client = require("distilled.client")
local rest = require("distilled.protocol.rest")
local S = require("distilled.schema")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")

-- the value of a call that must succeed
local function must(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

-- a scripted page call: returns pages[i] for the i-th request and records the requests;
-- a request past the script fails the test (a paginator that loops)
local function scripted(pages)
  local calls = { requests = {} }
  function calls.call(input)
    local n = #calls.requests + 1
    calls.requests[n] = input
    local page = pages[n]
    if page == nil then
      error("paginator made an unexpected extra request #" .. n, 0)
    end
    if errors.is(page) then
      return nil, page
    end
    if type(page) == "table" and page.__meta then
      return page.page, nil, page.__meta
    end
    return page
  end
  return calls
end

local function field(list, key)
  local out = {}
  for i, v in ipairs(list) do
    out[i] = v[key] == nil and "nil" or v[key]
  end
  return out
end

local CURSOR = {
  mode = "cursor",
  input_token = "cursor",
  output_token = "pagination.cursor",
  items = "items",
  page_size = "limit",
}

-- pagination.test.ts scenarios ("nil" stands for an absent cursor)
local SCENARIOS = {
  {
    name = "advances normally until the cursor is omitted",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "b" } },
      { items = { 3 } },
    },
    cursors = { "nil", "a", "b" },
    stop = "no_token",
  },
  {
    name = "terminates on null",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = json.null } },
    },
    cursors = { "nil", "a" },
    stop = "no_token",
  },
  {
    name = 'terminates on ""',
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "" } },
    },
    cursors = { "nil", "a" },
    stop = "no_token",
  },
  {
    name = "terminates on an empty page echoing the requested cursor",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = {}, pagination = { cursor = "a" } },
    },
    cursors = { "nil", "a" },
    stop = "repeated_cursor",
  },
  {
    name = "emits a nonempty page before stopping on a repeated cursor",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "a" } },
    },
    cursors = { "nil", "a" },
    stop = "repeated_cursor",
  },
  {
    name = "terminates when the first response echoes the initial cursor",
    start = "initial",
    pages = { { items = { 1 }, pagination = { cursor = "initial" } } },
    cursors = { "initial" },
    stop = "repeated_cursor",
  },
  {
    name = "terminates a multi-cursor cycle",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "b" } },
      { items = { 3 }, pagination = { cursor = "a" } },
    },
    cursors = { "nil", "a", "b" },
    stop = "repeated_cursor",
  },
  {
    name = "terminates a cycle returning to the initial cursor",
    start = "initial",
    pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "initial" } },
    },
    cursors = { "initial", "a" },
    stop = "repeated_cursor",
  },
  {
    name = "preserves empty and sparse pages whose cursors advance",
    pages = {
      { items = {}, pagination = { cursor = "a" } },
      { pagination = { cursor = "b" } },
      { items = { 1 }, pagination = { cursor = "c" } },
      { items = {}, pagination = { cursor = "d" } },
      { items = { 2 } },
    },
    cursors = { "nil", "a", "b", "c", "d" },
    stop = "no_token",
  },
}

t.describe("paginate: cursor mode (pagination.test.ts scenarios)", function()
  for _, sc in ipairs(SCENARIOS) do
    t.it(sc.name, function()
      local calls = scripted(sc.pages)
      local input = { cursor = sc.start, limit = 1 }
      local it = paginate.pages(calls.call, input, CURSOR)
      local pages = must(it:collect())
      t.eq(#pages, #sc.pages)
      for i = 1, #pages do
        t.eq(pages[i], sc.pages[i])
      end
      t.same(field(calls.requests, "cursor"), sc.cursors)
      for _, r in ipairs(calls.requests) do
        t.eq(r.limit, 1)
      end
      -- the caller's input is never changed
      t.eq(input.cursor, sc.start)
      t.eq(it.stop, sc.stop)
      t.eq(it.err, nil)
    end)

    t.it("item extraction: " .. sc.name, function()
      local calls = scripted(sc.pages)
      local items =
        must(paginate.items(calls.call, { cursor = sc.start, limit = 1 }, CURSOR):collect())
      local expected = {}
      for _, p in ipairs(sc.pages) do
        for _, item in ipairs(p.items or {}) do
          expected[#expected + 1] = item
        end
      end
      t.same(items, json.array(expected))
      t.same(field(calls.requests, "cursor"), sc.cursors)
    end)
  end

  t.it("extracts every item from a large page in order", function()
    local list = {}
    for i = 1, 20000 do
      list[i] = i
    end
    local calls = scripted({ { items = list } })
    local items = paginate.items(calls.call, {}, CURSOR):collect()
    t.eq(#items, 20000)
    t.eq(items[1], 1)
    t.eq(items[20000], 20000)
  end)

  t.it("cursor history is isolated across traversals of the same input", function()
    local pages = {
      { items = { 1 }, pagination = { cursor = "a" } },
      { items = { 2 }, pagination = { cursor = "b" } },
      { items = {}, pagination = { cursor = "b" } },
    }
    local counter = { n = 0 }
    local function call(input)
      counter.n = counter.n + 1
      if counter.n > 6 then
        error("exceeded the request bound", 0)
      end
      return pages[input.cursor == "a" and 2 or input.cursor == "b" and 3 or 1]
    end
    local input = {}
    t.eq(#paginate.pages(call, input, CURSOR):collect(), 3)
    t.eq(#paginate.pages(call, input, CURSOR):collect(), 3)
    t.eq(counter.n, 6)
  end)
end)

t.describe("paginate: token mode", function()
  local TOKEN = { input_token = "next_token", output_token = "next_token", items = "things" }

  t.it("is the default mode and sends the token back until it is absent", function()
    local calls = scripted({
      { things = { "a" }, next_token = "t1" },
      { things = { "b" }, next_token = "t2" },
      { things = { "c" } },
    })
    local items = paginate.items(calls.call, { max = 5 }, TOKEN):collect()
    t.same(items, json.array({ "a", "b", "c" }))
    t.same(field(calls.requests, "next_token"), { "nil", "t1", "t2" })
    t.eq(calls.requests[2].max, 5)
  end)

  t.it('stops on null and on "" (SSM, CloudWatch Logs)', function()
    for _, terminal in ipairs({ json.null, "" }) do
      local calls = scripted({
        { things = { 1 }, next_token = "t1" },
        { things = { 2 }, next_token = terminal },
      })
      local it = paginate.pages(calls.call, {}, TOKEN)
      t.eq(#it:collect(), 2)
      t.eq(it.stop, "no_token")
    end
  end)

  t.it("starts from the input's token; object tokens are passed back as they are", function()
    local key = { id = 7 }
    local calls = scripted({ { things = {}, next_token = key }, { things = {} } })
    paginate.pages(calls.call, { next_token = "start" }, TOKEN):collect()
    t.eq(calls.requests[1].next_token, "start")
    t.eq(calls.requests[2].next_token, key)
  end)
end)

t.describe("paginate: page mode", function()
  local PAGE =
    { mode = "page", input_token = "page", output_token = "result_info.next", items = "result" }

  t.it("takes an advancing page number from the output", function()
    local calls = scripted({
      { result = { 1 }, result_info = { next = 3 } },
      { result = { 2 }, result_info = { next = json.null } },
    })
    local it = paginate.pages(calls.call, {}, PAGE)
    it:collect()
    t.same(field(calls.requests, "page"), { 1, 3 })
    t.eq(it.stop, "no_token")
  end)

  t.it("a page number that does not advance (the CURRENT page, Cloudflare) increments", function()
    local trait =
      { mode = "page", input_token = "page", output_token = "result_info.page", items = "result" }
    local calls = scripted({
      { result = { 1 }, result_info = { page = 1 } },
      { result = { 2 }, result_info = { page = 2 } },
      { result = {}, result_info = { page = 3 } },
    })
    local it = paginate.pages(calls.call, { page = 1 }, trait)
    t.eq(#it:collect(), 3)
    t.same(field(calls.requests, "page"), { 1, 2, 3 })
    t.eq(it.stop, "empty_page")
  end)

  t.it("a null items member is an empty page", function()
    local trait =
      { mode = "page", input_token = "page", output_token = "result_info.page", items = "result" }
    local calls = scripted({ { result = json.null, result_info = { page = 1 } } })
    local it = paginate.pages(calls.call, {}, trait)
    t.eq(#it:collect(), 1)
    t.eq(it.stop, "empty_page")
  end)

  t.it("starts from a number in the input", function()
    local calls = scripted({ { result = { 1 } } })
    paginate.pages(calls.call, { page = 4 }, PAGE):collect()
    t.eq(calls.requests[1].page, 4)
  end)
end)

t.describe("paginate: relay mode", function()
  local RELAY = {
    mode = "relay",
    input_token = "after",
    output_token = "page_info.endCursor",
    items = "edges.node",
  }

  local function conn(nodes, cursor, has_next)
    local edges = {}
    for i, n in ipairs(nodes) do
      edges[i] = { node = n }
    end
    return { edges = json.array(edges), page_info = { endCursor = cursor, hasNextPage = has_next } }
  end

  t.it("follows endCursor while hasNextPage is true; items cross arrays (edges.node)", function()
    local calls = scripted({ conn({ "a", "b" }, "c1", true), conn({ "c" }, "c2", false) })
    local it = paginate.items(calls.call, { first = 2 }, RELAY)
    t.same(it:collect(), json.array({ "a", "b", "c" }))
    t.same(field(calls.requests, "after"), { "nil", "c1" })
    t.eq(it.stop, "no_next_page")
  end)

  t.it("the terminal page's endCursor does not keep it going (hasNextPage decides)", function()
    local calls = scripted({ conn({ "a" }, "c1", false) })
    local it = paginate.pages(calls.call, {}, RELAY)
    t.eq(#it:collect(), 1)
  end)

  t.it("an empty page ends the connection whatever hasNextPage claims", function()
    local calls = scripted({ conn({ "a" }, "c1", true), conn({}, "c2", true) })
    local it = paginate.pages(calls.call, {}, RELAY)
    t.eq(#it:collect(), 2)
    t.eq(it.stop, "empty_page")
  end)

  t.it("a stuck endCursor with hasNextPage true stops (Railway projects)", function()
    local calls = scripted({ conn({ "a" }, "c1", true), conn({ "b" }, "c1", true) })
    local it = paginate.pages(calls.call, {}, RELAY)
    t.eq(#it:collect(), 2)
    t.eq(it.stop, "stuck_cursor")
  end)

  t.it("a missing pageInfo ends the traversal", function()
    local calls = scripted({ { edges = json.array({ { node = 1 } }) } })
    local it = paginate.pages(calls.call, {}, RELAY)
    t.eq(#it:collect(), 1)
    t.eq(it.stop, "no_next_page")
  end)

  t.it("has_next_page names another path", function()
    local trait =
      { mode = "relay", input_token = "after", output_token = "cursor", has_next_page = "more" }
    local calls = scripted({ { cursor = "x", more = true }, { cursor = "y", more = false } })
    t.eq(#paginate.pages(calls.call, {}, trait):collect(), 2)
  end)
end)

t.describe("paginate: link mode", function()
  t.it("next_link finds rel=next among several links", function()
    t.eq(
      paginate.next_link(
        '<https://api.github.com/repositories/1/issues?page=2>; rel="next", <https://api.github.com/repositories/1/issues?page=5>; rel="last"'
      ),
      "https://api.github.com/repositories/1/issues?page=2"
    )
    t.eq(
      paginate.next_link(
        '<https://x.test/a?page=1>; rel="prev", <https://x.test/a?page=3>; rel="next"'
      ),
      "https://x.test/a?page=3"
    )
  end)

  t.it("next_link reads space-separated and unquoted rel values", function()
    t.eq(
      paginate.next_link('<https://x.test/a?after=c1>; rel="next last"'),
      "https://x.test/a?after=c1"
    )
    t.eq(paginate.next_link("<https://x.test/a?after=c1>;rel=next"), "https://x.test/a?after=c1")
  end)

  t.it("next_link is nil without a next link", function()
    t.eq(paginate.next_link('<https://x.test/a?page=1>; rel="first"'), nil)
    t.eq(paginate.next_link(nil), nil)
    t.eq(paginate.next_link(""), nil)
  end)

  t.it("query_param decodes like URLSearchParams", function()
    t.eq(paginate.query_param("https://x/a?b=1&after=c%2B1+x#frag", "after"), "c+1 x")
    t.eq(paginate.query_param("/a?after=", "after"), "")
    t.eq(paginate.query_param("/a", "after"), nil)
  end)

  local LINK = { mode = "link", input_token = "page" }
  local function page_with(body, link)
    return { page = body, __meta = { status = 200, headers = { link = link } } }
  end

  t.it("takes the token from the Link header the page call returns as its third value", function()
    local calls = scripted({
      page_with(json.array({ 1, 2 }), '<https://x.test/i?page=2>; rel="next"'),
      page_with(json.array({ 3 }), nil),
    })
    local it = paginate.items(calls.call, { per_page = 2 }, LINK)
    t.same(it:collect(), json.array({ 1, 2, 3 }))
    t.same(field(calls.requests, "page"), { "nil", "2" })
    t.eq(it.stop, "no_next_link")
  end)

  t.it("a repeated token stops", function()
    local calls = scripted({
      page_with(json.array({ 1 }), '<https://x.test/i?page=2>; rel="next"'),
      page_with(json.array({ 2 }), '<https://x.test/i?page=2>; rel="next"'),
    })
    local it = paginate.pages(calls.call, {}, LINK)
    t.eq(#it:collect(), 2)
    t.eq(it.stop, "repeated_token")
  end)

  t.it("a page call that returns no headers is the only page", function()
    local calls = scripted({ json.array({ 1 }) })
    t.eq(#paginate.pages(calls.call, {}, LINK):collect(), 1)
  end)
end)

t.describe("paginate: keyset mode (pagination.test.ts)", function()
  local KEYSET = {
    mode = "keyset",
    input_token = "pagination.created_before",
    output_token = "created_at",
    items = "dicts",
    page_size = "pagination.max_objects",
  }
  local ALL = {}
  for i, c in ipairs({ 50, 40, 30, 20, 10 }) do
    ALL[i] = { name = "d" .. c, created_at = c }
  end
  local function lister(requests)
    return function(input)
      requests[#requests + 1] = input
      local p = input.pagination or {}
      local before = p.created_before or 1 / 0
      local max = p.max_objects or 100
      local out = {}
      for _, d in ipairs(ALL) do
        if d.created_at < before and #out < max then
          out[#out + 1] = d
        end
      end
      return { dicts = json.array(out) }
    end
  end

  t.it("starts each page after the last item's key, in the nested input member", function()
    local requests = {}
    local input = { environment_name = "main", pagination = { max_objects = 2 } }
    local it = paginate.items(lister(requests), input, KEYSET)
    t.same(field(it:collect(), "name"), { "d50", "d40", "d30", "d20", "d10" })
    t.same(requests, {
      { environment_name = "main", pagination = { max_objects = 2 } },
      { environment_name = "main", pagination = { max_objects = 2, created_before = 40 } },
      { environment_name = "main", pagination = { max_objects = 2, created_before = 20 } },
    })
    t.eq(it.stop, "short_page")
    -- the nested input table was copied, not changed
    t.eq(input.pagination.created_before, nil)
  end)

  t.it("without a page size, ends on an empty page", function()
    local requests = {}
    local it = paginate.pages(lister(requests), { environment_name = "main" }, KEYSET)
    it:collect()
    t.same(requests, {
      { environment_name = "main" },
      { environment_name = "main", pagination = { created_before = 10 } },
    })
    t.eq(it.stop, "empty_page")
  end)

  t.it("a key that does not advance stops", function()
    local calls =
      scripted({ { dicts = { { created_at = 5 } } }, { dicts = { { created_at = 5 } } } })
    local it = paginate.pages(calls.call, {}, KEYSET)
    t.eq(#it:collect(), 2)
    t.eq(it.stop, "key_not_advancing")
  end)

  t.it("an item without a key stops", function()
    local calls = scripted({ { dicts = { { name = "x" } } } })
    local it = paginate.pages(calls.call, {}, KEYSET)
    t.eq(#it:collect(), 1)
    t.eq(it.stop, "no_token")
  end)
end)

t.describe("paginate: single mode and trait errors", function()
  t.it("single makes exactly one call", function()
    local calls = scripted({ { items = { 1, 2 } } })
    local it = paginate.items(calls.call, {}, { mode = "single", items = "items" })
    t.same(it:collect(), json.array({ 1, 2 }))
    t.eq(#calls.requests, 1)
    t.eq(it.stop, "single")
  end)

  t.it("a bare array page is its own item list", function()
    local calls = scripted({ json.array({ "x", "y" }) })
    t.same(paginate.items(calls.call, {}, { mode = "single" }):collect(), json.array({ "x", "y" }))
  end)

  t.it("a trait missing a field its mode reads fails with SdkError before any call", function()
    for _, trait in ipairs({
      { mode = "token", input_token = "t" },
      { mode = "cursor", output_token = "c" },
      { mode = "page" },
      { mode = "relay", input_token = "a" },
      { mode = "link" },
      { mode = "keyset", input_token = "a", output_token = "b" },
      { mode = "sideways", input_token = "a", output_token = "b" },
    }) do
      local calls = scripted({})
      local it = paginate.pages(calls.call, {}, trait)
      t.fails_with("SdkError", it:collect())
      t.eq(#calls.requests, 0)
      t.eq(it.stop, "error")
    end
  end)
end)

t.describe("paginate: the iterator object", function()
  local function three_pages()
    return scripted({
      { items = { 1, 2 }, pagination = { cursor = "a" } },
      { items = { 3, 4 }, pagination = { cursor = "b" } },
      { items = { 5 } },
    })
  end

  t.it("is callable in a for loop", function()
    local calls = three_pages()
    local seen = {}
    local it = paginate.items(calls.call, {}, CURSOR)
    for x in it do
      seen[#seen + 1] = x
    end
    t.same(seen, { 1, 2, 3, 4, 5 })
    t.eq(it.err, nil)
    t.truthy(it.done)
    t.eq(it.count, 5)
    t.eq(it.pages, 3)
  end)

  t.it("collect(limit) stops fetching pages once enough items are collected", function()
    local calls = three_pages()
    local it = paginate.items(calls.call, {}, CURSOR)
    t.same(it:collect(3), json.array({ 1, 2, 3 }))
    t.eq(#calls.requests, 2)
    t.eq(it.stop, "limit")
    -- closed: no more calls
    t.eq(it(), nil)
    t.eq(#calls.requests, 2)
  end)

  t.it("collect(limit) on pages counts pages", function()
    local calls = three_pages()
    t.eq(#paginate.pages(calls.call, {}, CURSOR):collect(1), 1)
    t.eq(#calls.requests, 1)
  end)

  t.it("collect(0) makes no call; an empty listing collects an empty array", function()
    local calls = scripted({ { items = {} } })
    local list = paginate.items(calls.call, {}, CURSOR):collect(0)
    t.eq(#list, 0)
    t.eq(json.encode(list), "[]")
    t.eq(#calls.requests, 0)
    t.eq(json.encode(paginate.items(calls.call, {}, CURSOR):collect()), "[]")
  end)

  t.it("stops at the first failure and records it in it.err", function()
    local failure = errors.new("ServiceUnavailable", { status = 503 })
    local calls = scripted({ { items = { 1 }, pagination = { cursor = "a" } }, failure })
    local it = paginate.items(calls.call, {}, CURSOR)
    local seen = {}
    for x in it do
      seen[#seen + 1] = x
    end
    t.same(seen, { 1 })
    t.eq(it.err, failure)
    t.eq(it.stop, "error")
    t.eq(it(), nil)
    t.eq(#calls.requests, 2)
  end)

  t.it("collect returns nil, err on failure", function()
    local failure = errors.new("NotFound", { status = 404 })
    local calls = scripted({ failure })
    t.fails_with("NotFound", paginate.pages(calls.call, {}, CURSOR):collect())
  end)

  t.it("close stops the traversal and is idempotent", function()
    local calls = three_pages()
    local it = paginate.pages(calls.call, {}, CURSOR)
    t.truthy(it())
    it:close()
    it:close()
    t.eq(it(), nil)
    t.eq(it.stop, "closed")
    t.eq(#calls.requests, 1)
  end)

  t.it("misuse raises", function()
    t.raises(function()
      paginate.pages("nope", {}, CURSOR)
    end, "call must be a function")
    t.raises(function()
      paginate.pages(function() end, {}, nil)
    end, "trait must be a table")
    t.raises(function()
      paginate.items(function() end, {}, CURSOR):collect(-1)
    end, "limit")
  end)

  t.it("get_path and get_items", function()
    local v = { a = { b = { c = 1 } }, list = json.array({ { n = 1 }, json.null, { n = 2 } }) }
    t.eq(paginate.get_path(v, "a.b.c"), 1)
    t.eq(paginate.get_path(v, "a.x.c"), nil)
    t.eq(paginate.get_path({ a = json.null }, "a.b"), nil)
    t.same(paginate.get_items(v, "list.n"), { 1, 2 })
    t.same(paginate.get_items({ x = { y = json.null } }, "x.y"), {})
  end)
end)

---------------------------------------------------------------------------------------
-- through a client: page calls are operations, the traversal is one span
---------------------------------------------------------------------------------------

local function neon(responses, opts)
  opts = opts or {}
  local service = fixtures.service()
  service.telemetry = { system = "neon-api", prefix = "Neon", service = "Neon", labels = "neon" }
  for _, op in pairs(service.ops) do
    op.span = op.name
  end
  service.ops.list_repos = {
    name = "ListRepos",
    method = "GET",
    uri = "/repos",
    input = S.struct({
      name = "ListReposRequest",
      members = {
        S.member({ name = "page", bind = "query", schema = S.string }),
        S.member({ name = "per_page", bind = "query", schema = S.number }),
      },
    }),
    output = S.list(S.string),
    output_raw = true,
    errors = {},
    pagination = { mode = "link", input_token = "page" },
    span = "ListRepos",
  }
  local Neon = Client.define({
    service = service,
    protocol = rest.new({ base_url = fixtures.BASE_URL, headers = rest.bearer("api_key") }),
    options = { api_key = { secret = true } },
  })
  local host = testing.host({ responses = responses, seed = 3 })
  host.random = function()
    return 0.5
  end
  local memory = trace.exporters.memory()
  local tracer = trace.new({ level = opts.level or "operation", exporter = memory, host = host })
  local client = Neon.new({ api_key = "k", host = host, tracer = tracer })
  return client, host, memory
end

t.describe("paginate: through a client", function()
  t.it("one traversal span with one operation span per page", function()
    local client, host, memory = neon({
      { body = fixtures.bodies.page({ "a", "b" }, "c1") },
      { body = fixtures.bodies.page({ "c" }) },
    })
    local items = must(client:list_projects_items({ limit = 2 }):collect())
    t.same(field(items, "id"), { "a", "b", "c" })
    t.eq(#host.requests, 2)
    t.match(host.requests[2].url, "cursor=c1", true)
    local e = expect(memory.spans)
    local root = e:span("distilled.pagination")
      :attr("distilled.pagination.pages", 2)
      :attr("distilled.pagination.items", 3)
      :attr("distilled.pagination.stop", "no_token")
      :attr("distilled.pagination.operation", "Neon.ListProjects")
      :attr("rpc.method", "Neon/ListProjects")
    root:children("Neon.ListProjects"):count(2)
    e:count(3)
  end)

  t.it("a failing page fails the traversal span and records it.err", function()
    local client, _, memory = neon({
      { body = fixtures.bodies.page({ "a" }, "c1") },
      { status = 400, body = { message = "bad cursor" } },
    })
    local it = client:list_projects_items({})
    local list, err = it:collect()
    t.eq(list, nil)
    t.eq(err.tag, "BadRequest")
    t.eq(it.err, err)
    local e = expect(memory.spans)
    e:span("distilled.pagination"):failed("BadRequest"):attr("distilled.pagination.stop", "error")
    e:spans("Neon.ListProjects"):count(2)
  end)

  t.it(
    "work between pulls is not parented to the traversal span; an abandoned iterator does not capture later spans",
    function()
      local client, _, memory = neon({
        { body = fixtures.bodies.page({ "a" }, "c1") },
        { body = fixtures.bodies.project("p1") },
        { body = fixtures.bodies.project("p2") },
      })
      local it = client:list_projects_pages({})
      t.truthy(it())
      t.truthy(client:get_project({ project_id = "p1" }))
      -- `break` out of the loop: never closed
      t.truthy(client:get_project({ project_id = "p2" }))
      it:close()
      local e = expect(memory.spans)
      for _, s in ipairs(e:spans("Neon.GetProject"):list()) do
        t.eq(s.parent_span_id, nil)
      end
      e:span("distilled.pagination"):attr("distilled.pagination.stop", "closed")
    end
  )

  t.it("link mode reads the Link header through the REST protocol (bare-array pages)", function()
    local client, host = neon({
      {
        body = json.array({ "r1", "r2" }),
        headers = { Link = '<https://x.test/repos?page=2>; rel="next"' },
      },
      {
        body = json.array({ "r3" }),
        headers = { link = '<https://x.test/repos?page=1>; rel="first"' },
      },
    })
    local it = client:list_repos_items({ per_page = 2 })
    t.same(it:collect(), json.array({ "r1", "r2", "r3" }))
    t.match(host.requests[2].url, "page=2", true)
    t.eq(it.stop, "no_next_link")
  end)

  t.it("pages are the bare arrays; a response without a Link header is the only page", function()
    local client, host = neon({ { body = json.array({ "r1" }) } })
    local pages = client:list_repos_pages({}):collect()
    t.eq(#pages, 1)
    t.same(pages[1], json.array({ "r1" }))
    t.eq(#host.requests, 1)
  end)

  t.it("each page call retries on its own", function()
    local client, host, memory = neon({
      { body = fixtures.bodies.page({ "a" }, "c1") },
      { status = 503 },
      { body = fixtures.bodies.page({ "b" }) },
    })
    t.eq(#client:list_projects_items({}):collect(), 2)
    t.eq(#host.requests, 3)
    expect(memory.spans):spans("Neon.ListProjects"):nth(2):attr("distilled.attempts", 2)
  end)

  t.it("with tracing off nothing is recorded and pagination still works", function()
    local service = fixtures.service()
    local Neon =
      Client.define({ service = service, protocol = rest.new({ base_url = fixtures.BASE_URL }) })
    local host = testing.host({
      responses = {
        { body = fixtures.bodies.page({ "a" }, "c1") },
        { body = fixtures.bodies.page({ "b" }) },
      },
    })
    local client = Neon.new({ host = host })
    t.eq(#client:list_projects_items({}):collect(), 2)
  end)
end)
