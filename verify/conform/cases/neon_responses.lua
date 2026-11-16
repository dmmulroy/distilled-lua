-- Hand-written response cases for dl conform neon. Each case gives an operation, an
-- optional input (default: the minimal one), a canned response and optionally a
-- validation mode. `json` is encoded into the body (with a JSON content type); `body`
-- is sent as is; `body_b64` for bytes.
local json = require("distilled.json")

local cases = {}
local function add(c)
  cases[#cases + 1] = c
end

local PROJECT = {
  project = {
    id = "p1",
    name = "demo",
    region_id = "aws-us-east-2",
    platform_id = "aws",
    pg_version = 17,
    created_at = "2024-01-01T00:00:00Z",
    updated_at = "2024-01-01T00:00:00Z",
  },
}

-- success shapes ------------------------------------------------------------------------
add({ id = "get_project/empty-200", op = "get_project", response = { status = 200, body = "" } })
add({ id = "get_project/204", op = "get_project", response = { status = 204 } })
add({
  id = "get_project/non-json-200",
  op = "get_project",
  response = {
    status = 200,
    headers = { ["content-type"] = "text/html" },
    body = "<html>oops</html>",
  },
})
add({
  id = "get_project/json-without-content-type",
  op = "get_project",
  response = { status = 200, body = '{"project":{"id":"p1"}}' },
})
add({
  id = "get_project/null-body",
  op = "get_project",
  response = { status = 200, json = json.null },
})
add({
  id = "get_project/array-body",
  op = "get_project",
  response = { status = 200, json = json.array({ 1, 2 }) },
})
add({
  id = "create_api_key/secret-key",
  op = "create_api_key",
  input = { key_name = "k" },
  response = {
    status = 200,
    json = { id = 1, key = "napi_secret", name = "k", created_at = "t", created_by = "u" },
  },
})
add({
  id = "create_api_key/non-json-secret-output",
  op = "create_api_key",
  input = { key_name = "k" },
  response = { status = 200, body = "key=napi_secret" },
})
add({
  id = "list_api_keys/array",
  op = "list_api_keys",
  response = { status = 200, json = json.array({ { id = 1, name = "a" }, { id = 2, name = "b" } }) },
})
add({
  id = "list_api_keys/empty-array",
  op = "list_api_keys",
  response = { status = 200, json = json.array({}) },
})

-- validation modes ----------------------------------------------------------------------
local extra = { project = { id = "p1", name = "demo", zz_unmodelled = true }, zz_top = 1 }
local wrong = { project = "not an object" }
local missing = { project = { name = "no id" } }
for _, mode in ipairs({ "lenient", "additional", "strict" }) do
  add({
    id = "get_project/extra-keys-" .. mode,
    op = "get_project",
    validation = mode,
    response = { json = extra },
  })
  add({
    id = "get_project/wrong-type-" .. mode,
    op = "get_project",
    validation = mode,
    response = { json = wrong },
  })
  add({
    id = "get_project/missing-required-" .. mode,
    op = "get_project",
    validation = mode,
    response = { json = missing },
  })
  add({
    id = "get_project/valid-" .. mode,
    op = "get_project",
    validation = mode,
    response = { json = PROJECT },
  })
  add({
    id = "create_api_key/wrong-type-" .. mode,
    op = "create_api_key",
    input = { key_name = "k" },
    validation = mode,
    response = {
      json = { id = "one", key = "napi_secret", name = "k", created_at = "t", created_by = "u" },
    },
  })
end

-- declared errors by matcher ------------------------------------------------------------
local ERR = { code = "E1", message = "it failed" }
add({ id = "get_project/400", op = "get_project", response = { status = 400, json = ERR } })
add({ id = "get_project/404", op = "get_project", response = { status = 404, json = ERR } })
add({
  id = "get_project/404-message-only",
  op = "get_project",
  response = { status = 404, json = { message = "project not found" } },
})
add({ id = "get_project/404-no-body", op = "get_project", response = { status = 404 } })
add({
  id = "get_project/404-non-json",
  op = "get_project",
  response = { status = 404, headers = { ["content-type"] = "text/plain" }, body = "nope" },
})
add({
  id = "get_project/404-numeric-code",
  op = "get_project",
  response = { status = 404, json = { code = 4040, message = "numeric" } },
})
add({
  id = "get_project/404-extra-fields",
  op = "get_project",
  response = {
    status = 404,
    json = { code = "E", message = "m", request_id = "r1", details = { a = 1 } },
  },
})
add({
  id = "get_project/404-retry-after",
  op = "get_project",
  response = { status = 404, headers = { ["retry-after"] = "5" }, json = ERR },
})
for _, status in ipairs({ 400, 404, 409, 422 }) do
  add({
    id = "create_project_branch_database/" .. status,
    op = "create_project_branch_database",
    response = { status = status, json = ERR },
  })
end
add({
  id = "create_project_branch_bucket/403",
  op = "create_project_branch_bucket",
  response = { status = 403, json = ERR },
})
add({
  id = "get_project_branch_bucket_object/403",
  op = "get_project_branch_bucket_object",
  response = { status = 403, json = ERR },
})

-- the status map and fallbacks, on an operation that declares no errors -----------------
for _, status in ipairs({
  300,
  400,
  401,
  402,
  403,
  404,
  405,
  408,
  409,
  410,
  418,
  422,
  423,
  429,
  500,
  501,
  502,
  503,
  504,
  599,
}) do
  add({
    id = "get_project_advisor_security_issues/" .. status,
    op = "get_project_advisor_security_issues",
    response = { status = status, json = ERR },
  })
end
add({
  id = "get_project_advisor_security_issues/500-no-body",
  op = "get_project_advisor_security_issues",
  response = { status = 500 },
})
add({
  id = "get_project_advisor_security_issues/502-html",
  op = "get_project_advisor_security_issues",
  response = {
    status = 502,
    headers = { ["content-type"] = "text/html" },
    body = "<h1>bad gateway</h1>",
  },
})

-- Retry-After ---------------------------------------------------------------------------
-- The fake clock on both sides reads 1700000000 s (Tue, 14 Nov 2023 22:13:20 GMT).
local RETRY_AFTER = {
  { "seconds", "7" },
  { "zero", "0" },
  { "fraction", "1.5" },
  { "negative", "-3" },
  { "garbage", "soon" },
  { "date", "Tue, 14 Nov 2023 22:13:30 GMT" },
  { "date-past", "Tue, 14 Nov 2023 22:13:00 GMT" },
  { "date-rfc850", "Tuesday, 14-Nov-23 22:13:30 GMT" },
  { "date-asctime", "Tue Nov 14 22:13:30 2023" },
  { "huge", "100000" },
}
for _, ra in ipairs(RETRY_AFTER) do
  for _, status in ipairs({ 429, 503 }) do
    add({
      id = "get_project_advisor_security_issues/" .. status .. "-retry-after-" .. ra[1],
      op = "get_project_advisor_security_issues",
      response = { status = status, headers = { ["retry-after"] = ra[2] }, json = ERR },
    })
  end
end

return cases
