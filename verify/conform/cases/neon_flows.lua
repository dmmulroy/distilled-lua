-- Flow cases for dl conform neon: scripted response sequences through a whole call,
-- pagination traversal or retry loop. Both sides use a fake clock starting at
-- 1700000000 s and jitter pinned to 0.5, and each case starts with a fresh retry budget.
--
--   kind    = "call" | "pages" | "items"
--   retry   = "default" (the provider's policy) | "none" | "throttling" | "transient"
--   script  = responses in order; past the end, `forever` (when given) or a transport failure
--   "transport" in a script is a transport failure
local json = require("distilled.json")

local cases = {}
local function add(c)
  c.retry = c.retry or "default"
  c.kind = c.kind or "call"
  cases[#cases + 1] = c
end

local OK_PROJECT = { status = 200, json = { project = { id = "p1", name = "demo" } } }
local function err(status, headers)
  return { status = status, headers = headers, json = { message = "status " .. status } }
end

local function page(ids, cursor_field, cursor)
  local items = json.array({})
  for i, id in ipairs(ids) do
    items[i] = { id = id, name = "n-" .. id }
  end
  local body = { projects = items }
  if cursor_field then
    body.pagination = { [cursor_field] = cursor }
  end
  return { status = 200, json = body }
end

-- retry ---------------------------------------------------------------------------------
local P = { project_id = "p1" }
add({
  id = "retry/503-503-200",
  op = "get_project",
  input = P,
  script = { err(503), err(503), OK_PROJECT },
})
add({ id = "retry/500-then-200", op = "get_project", input = P, script = { err(500), OK_PROJECT } })
add({
  id = "retry/502-504-200",
  op = "get_project",
  input = P,
  script = { err(502), err(504), OK_PROJECT },
})
add({
  id = "retry/429-retry-after-2",
  op = "get_project",
  input = P,
  script = { err(429, { ["retry-after"] = "2" }), OK_PROJECT },
})
add({
  id = "retry/429-retry-after-date",
  op = "get_project",
  input = P,
  script = { err(429, { ["retry-after"] = "Tue, 14 Nov 2023 22:13:25 GMT" }), OK_PROJECT },
})
add({
  id = "retry/503-retry-after-over-cap",
  op = "get_project",
  input = P,
  script = { err(503, { ["retry-after"] = "120" }), OK_PROJECT },
})
add({
  id = "retry/429-twice-throttle-backoff",
  op = "get_project",
  input = P,
  script = { err(429), err(429), OK_PROJECT },
})
add({ id = "retry/exhausted-503", op = "get_project", input = P, script = {}, forever = err(503) })
add({ id = "retry/exhausted-429", op = "get_project", input = P, script = {}, forever = err(429) })
add({
  id = "retry/404-not-retried",
  op = "get_project",
  input = P,
  script = { err(404), OK_PROJECT },
})
add({
  id = "retry/400-not-retried",
  op = "get_project",
  input = P,
  script = { err(400), OK_PROJECT },
})
add({
  id = "retry/401-not-retried",
  op = "get_project",
  input = P,
  script = { err(401), OK_PROJECT },
})
add({ id = "retry/423-locked", op = "get_project", input = P, script = { err(423), OK_PROJECT } })
add({
  id = "retry/408-timeout-status",
  op = "get_project",
  input = P,
  script = { err(408), OK_PROJECT },
})
add({
  id = "retry/transport-then-200",
  op = "get_project",
  input = P,
  script = { "transport", OK_PROJECT },
})
add({ id = "retry/transport-exhausted", op = "get_project", input = P, script = {} })
add({
  id = "retry/post-503-then-200",
  op = "create_api_key",
  input = { key_name = "k" },
  script = {
    err(503),
    {
      status = 200,
      json = { id = 1, key = "napi_x", name = "k", created_at = "t", created_by = "u" },
    },
  },
})
add({
  id = "retry/delete-500-then-200",
  op = "delete_project",
  input = P,
  script = { err(500), OK_PROJECT },
})
add({
  id = "retry/none-503",
  op = "get_project",
  input = P,
  retry = "none",
  script = { err(503), OK_PROJECT },
})
add({
  id = "retry/throttling-503-not-retried",
  op = "get_project",
  input = P,
  retry = "throttling",
  script = { err(503), OK_PROJECT },
})
add({
  id = "retry/throttling-429x4",
  op = "get_project",
  input = P,
  retry = "throttling",
  script = { err(429), err(429), err(429), err(429), OK_PROJECT },
})
add({
  id = "retry/transient-503x5",
  op = "get_project",
  input = P,
  retry = "transient",
  script = { err(503), err(503), err(503), err(503), err(503), OK_PROJECT },
})
-- No "transient until the budget runs out" case: Distilled's transient policy has no
-- budget and retries forever (retry.ts transientFactory), so that flow never ends there.

-- pagination ----------------------------------------------------------------------------
add({
  id = "pages/items-three-pages",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = {
    page({ "a", "b" }, "cursor", "c1"),
    page({ "c" }, "cursor", "c2"),
    page({}, "cursor", json.null),
  },
})
add({
  id = "pages/pages-three-pages",
  kind = "pages",
  op = "list_projects",
  input = { limit = 2 },
  script = {
    page({ "a", "b" }, "cursor", "c1"),
    page({ "c", "d" }, "cursor", "c2"),
    page({ "e" }, "cursor", ""),
  },
})
add({
  id = "pages/no-pagination-field",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({ "a" }) },
})
add({
  id = "pages/repeated-cursor",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = {
    page({ "a" }, "cursor", "same"),
    page({ "b" }, "cursor", "same"),
    page({ "c" }, "cursor", "same"),
  },
})
add({
  id = "pages/start-cursor",
  kind = "items",
  op = "list_projects",
  input = { cursor = "start", search = "x y" },
  script = { page({ "a" }, "cursor", "next 1/2"), page({ "b" }, "cursor", json.null) },
})
add({
  id = "pages/start-cursor-returned",
  kind = "items",
  op = "list_projects",
  input = { cursor = "start" },
  script = { page({ "a" }, "cursor", "start"), page({ "b" }) },
})
add({
  id = "pages/empty-first-page",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({}, "cursor", json.null) },
})
add({
  id = "pages/empty-page-with-cursor",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({}, "cursor", "c1"), page({ "a" }, "cursor", json.null) },
})
add({
  id = "pages/missing-items-key",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { { status = 200, json = { pagination = { cursor = "c1" } } }, page({ "a" }) },
})
add({
  id = "pages/failure-on-page-2",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({ "a", "b" }, "cursor", "c1"), err(404) },
})
add({
  id = "pages/pages-failure-on-page-2",
  kind = "pages",
  op = "list_projects",
  input = json.object({}),
  script = { page({ "a" }, "cursor", "c1"), err(400) },
})
add({
  id = "pages/retry-inside-page-2",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({ "a" }, "cursor", "c1"), err(503), page({ "b" }, "cursor", json.null) },
})
add({
  id = "pages/next-field",
  kind = "items",
  op = "list_project_branches",
  input = { project_id = "p 1" },
  script = {
    {
      status = 200,
      json = { branches = json.array({ { id = "b1" } }), pagination = { next = "n1" } },
    },
    {
      status = 200,
      json = { branches = json.array({ { id = "b2" } }), pagination = { next = "" } },
    },
  },
})
add({
  id = "pages/numeric-cursor",
  kind = "items",
  op = "list_projects",
  input = json.object({}),
  script = { page({ "a" }, "cursor", 5), page({ "b" }, "cursor", json.null) },
})

return cases
