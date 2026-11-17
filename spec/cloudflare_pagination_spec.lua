-- Cloudflare pagination (paginate.lua strategies["cloudflare.page"], plus the core cursor
-- mode on result_info paths). The page cases are Distilled's packages/cloudflare/test/
-- pagination.test.ts, through the generated secrets_store client.
local t = require("spec.harness")
local json = require("distilled.json")
local paginate = require("distilled.paginate")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local SecretsStore = require("cloudflare.secrets_store")
local Accounts = require("cloudflare.accounts")

local function secret_item(name)
  return {
    id = "id-" .. name,
    created = "2026-01-01T00:00:00Z",
    modified = "2026-01-01T00:00:00Z",
    name = name,
    status = "active",
    store_id = "store",
  }
end

-- a transport serving `pages` (1-indexed) with result_info from info(page, items); it
-- records the page number of every request
local function list(pages, info, input)
  local requested = {}
  local transport = function(req)
    local page = tonumber(paginate.query_param(req.url, "page"))
    requested[#requested + 1] = page
    local items = pages[page] or {}
    local result = json.array({})
    for i, name in ipairs(items) do
      result[i] = secret_item(name)
    end
    local body =
      { success = true, errors = json.array({}), messages = json.array({}), result = result }
    body.result_info = info(page, items)
    return {
      status = 200,
      headers = { ["content-type"] = "application/json" },
      body = json.encode(body),
    }
  end
  local client = SecretsStore.new({ transport = transport, api_token = "token", retry = "none" })
  local args = { account_id = "account", store_id = "store" }
  for k, v in pairs(input or {}) do
    args[k] = v
  end
  local it = client:list_store_secrets_items(args)
  local got, err = it:collect()
  local names = {}
  for i, s in ipairs(got or {}) do
    names[i] = s.name
  end
  return requested, names, err, it
end

local function names_of(prefix, n)
  local out = {}
  for i = 0, n - 1 do
    out[#out + 1] = prefix .. "-" .. i
  end
  return out
end

t.describe("cloudflare page pagination", function()
  t.it("stops after a short page that reaches total_count", function()
    local requested, got = list({ { "only" } }, function(page, items)
      return { page = page, per_page = 20, count = #items, total_count = 1 }
    end)
    t.same(requested, { 1 })
    t.same(got, { "only" })
  end)

  t.it("stops after the last short page of several", function()
    local pages = { names_of("a", 20), names_of("b", 20), names_of("c", 3) }
    local requested, got = list(pages, function(page, items)
      return { page = page, per_page = 20, count = #items, total_count = 43 }
    end)
    t.same(requested, { 1, 2, 3 })
    t.eq(#got, 43)
  end)

  t.it("stops at total_pages", function()
    local pages = { names_of("a", 2), names_of("b", 2) }
    local requested, got, _, it = list(pages, function(page, items)
      return { page = page, per_page = 2, count = #items, total_count = 4, total_pages = 2 }
    end)
    t.same(requested, { 1, 2 })
    t.eq(#got, 4)
    t.eq(it.stop, "last_page")
  end)

  t.it("asks for one more page when a full last page exactly reaches total_count", function()
    local pages = { names_of("a", 2), names_of("b", 2) }
    local requested, _, _, it = list(pages, function(page, items)
      return { page = page, per_page = 2, count = #items, total_count = 4 }
    end)
    t.same(requested, { 1, 2, 3 })
    t.eq(it.stop, "empty_page")
  end)

  t.it("keeps paging past a short page when total_count is not reached", function()
    local pages = { names_of("a", 10), names_of("b", 10), names_of("c", 5) }
    local requested, got = list(pages, function(page, items)
      return { page = page, per_page = 20, count = #items, total_count = 25 }
    end)
    t.same(requested, { 1, 2, 3 })
    t.eq(#got, 25)
  end)

  t.it("falls back to the requested per_page when result_info omits it", function()
    local requested = list({ { "only" } }, function(page, items)
      return { page = page, count = #items, total_count = 1 }
    end, { per_page = 50 })
    t.same(requested, { 1 })
  end)

  t.it("pages until an empty page when result_info has no totals", function()
    local requested, got = list({ names_of("a", 20), { "last" } }, function()
      return nil
    end)
    t.same(requested, { 1, 2, 3 })
    t.eq(#got, 21)
  end)

  t.it("stops without the duplicate when the server ignores the page parameter", function()
    -- every request answers page 1 (a request schema without the page parameter)
    local requested, got, err, it = list({ { "x", "y" }, { "x", "y" } }, function(_, items)
      return { page = 1, per_page = 2, count = #items }
    end)
    t.eq(err, nil)
    t.same(requested, { 1, 2 })
    t.same(got, { "x", "y" })
    t.eq(it.stop, "page_not_advancing")
  end)

  t.it("starts at the input's page", function()
    local requested, got = list({ { "a" }, { "b" }, {} }, function(page, items)
      return { page = page, count = #items }
    end, { page = 2 })
    t.same(requested, { 2, 3 })
    t.same(got, { "b" })
  end)

  t.it("_pages yields whole pages with result_info", function()
    local transport = function()
      return {
        status = 200,
        headers = {},
        body = json.encode({
          success = true,
          result = json.array({ secret_item("a") }),
          result_info = { page = 1, per_page = 20, count = 1, total_count = 1 },
        }),
      }
    end
    local client = SecretsStore.new({ transport = transport, api_token = "t" })
    local pages, err =
      client:list_store_secrets_pages({ account_id = "a", store_id = "s" }):collect()
    t.eq(err, nil)
    t.eq(#pages, 1)
    t.eq(pages[1].result_info.total_count, 1)
    t.eq(pages[1].result[1].name, "a")
  end)

  t.it("a failed page ends the traversal with the error", function()
    local n = 0
    local transport = function()
      n = n + 1
      if n == 2 then
        return {
          status = 200,
          headers = {},
          body = json.encode({
            success = false,
            errors = json.array({ { code = 424242, message = "nope" } }),
          }),
        }
      end
      return {
        status = 200,
        headers = {},
        body = json.encode({ success = true, result = json.array({ secret_item("a") }) }),
      }
    end
    local client = SecretsStore.new({ transport = transport, api_token = "t", retry = "none" })
    local it = client:list_store_secrets_items({ account_id = "a", store_id = "s" })
    local got, err = it:collect()
    t.eq(got, nil)
    t.fails_with("UnknownCloudflareError", nil, err)
    t.eq(n, 2)
  end)
end)

t.describe("cloudflare cursor pagination", function()
  t.it("follows result_info.cursors.after until it is absent", function()
    local cursors = {}
    local transport = function(req)
      local c = paginate.query_param(req.url, "cursor")
      cursors[#cursors + 1] = c or "-"
      local after = (c == nil) and "c2" or (c == "c2" and "c3" or nil)
      local info = { count = 1 }
      if after then
        info.cursors = { after = after }
      end
      return {
        status = 200,
        headers = {},
        body = json.encode({
          success = true,
          result = json.array({ { id = c or "first" } }),
          result_info = info,
        }),
      }
    end
    local client = Accounts.new({ transport = transport, api_token = "t" })
    local items, err = client:list_log_audits_items({ account_id = "a" }):collect()
    t.eq(err, nil)
    t.same(cursors, { "-", "c2", "c3" })
    t.eq(#items, 3)
  end)

  t.it("a strategy name without a provider strategy falls back to the core mode", function()
    local seen = {}
    local it = paginate.items(function(input)
      seen[#seen + 1] = input.cursor or "-"
      return { result = { 1 }, info = { next = input.cursor == nil and "n" or nil } }
    end, {}, {
      mode = "cursor",
      strategy = "cloudflare",
      input_token = "cursor",
      output_token = "info.next",
      items = "result",
    })
    local list = it:collect()
    t.same(seen, { "-", "n" })
    t.eq(#list, 2)
  end)

  t.it("cloudflare.page needs an input_token", function()
    local it = paginate.pages(function()
      return {}
    end, {}, { mode = "page", strategy = "cloudflare" })
    local _, err = it:collect()
    t.fails_with("SdkError", nil, err)
  end)
end)
