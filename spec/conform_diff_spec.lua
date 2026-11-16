-- verify/conform helpers: the field-level differ, the case-format mapping, base64, and the
-- intended-difference rules (each rule must match only what it says).
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local diff = require("verify.conform.diff")
local lib = require("verify.conform.lib")
local intended = require("verify.conform.intended")

local function paths(list)
  local out = {}
  for i, d in ipairs(list) do
    out[i] = d.path
  end
  return out
end

t.describe("conform diff", function()
  t.it("urls: path bytes, query content, query order and query encoding are separate", function()
    t.same(paths(diff.urls("https://h/a%20b?x=1&y=2", "https://h/a%20b?x=1&y=2", {})), {})
    t.same(paths(diff.urls("https://h/a%20b", "https://h/a+b", {})), { "url.path" })
    t.same(
      paths(diff.urls("https://h/p?x=1&y=2", "https://h/p?y=2&x=1", {})),
      { "url.query_order" }
    )
    t.same(paths(diff.urls("https://h/p?x=1", "https://h/p?x=2", {})), { "url.query" })
    t.same(
      paths(diff.urls("https://h/p?x=a+b", "https://h/p?x=a%20b", {})),
      { "url.query_encoding" }
    )
    t.same(paths(diff.urls("https://h/p?x=1&x=2", "https://h/p?x=1", {})), { "url.query" })
    -- "k" and "k=" differ (no value vs empty value)
    t.same(paths(diff.urls("https://h/p?k", "https://h/p?k=", {})), { "url.query" })
  end)

  t.it("values: nested paths, absent vs null, arrays vs objects, empty tables", function()
    local a = json.decode('{"a":{"b":[1,2,{"c":null}]},"e":[]}')
    local b = json.decode('{"a":{"b":[1,3,{}]},"e":{}}')
    t.same(paths(diff.values(a, b, "body", {})), { "body.a.b[1]", "body.a.b[2].c", "body.e" })
    t.same(diff.values(json.decode("[]"), {}, "", {})[1].path, "")
    t.same(#diff.values({}, json.object({}), "", {}), 0)
    t.same(#diff.values(1, 1.0, "", {}), 0)
  end)

  t.it("bodies: parsed as JSON only when the content type says so", function()
    t.same(#diff.bodies('{"a":1, "b":2}', '{"b":2,"a":1}', "application/json", {}), 0)
    t.same(paths(diff.bodies('{"a":1}', '{"a": 1}', "text/plain", {})), { "body" })
    t.same(paths(diff.bodies(nil, "", "application/json", {})), { "body" })
  end)
end)

t.describe("conform lib", function()
  t.it("to_lua maps { $secret } to a secret and keeps nulls and array marks", function()
    local v =
      lib.to_lua(json.decode('{"k":{"$secret":"s"},"n":null,"l":[],"o":{"$secret":"x","y":1}}'))
    t.truthy(secret.is(v.k))
    t.eq(secret.unwrap(v.k), "s")
    t.eq(v.n, json.null)
    t.truthy(json.is_array(v.l))
    t.falsy(secret.is(v.o)) -- only a lone $secret key is a secret
  end)

  t.it("base64 round-trips every byte value", function()
    local bytes = {}
    for i = 0, 255 do
      bytes[#bytes + 1] = string.char(i)
    end
    local s = table.concat(bytes)
    for _, cut in ipairs({ 0, 1, 2, 3, 255, 256 }) do
      local part = string.sub(s, 1, cut)
      t.eq(lib.b64_decode(lib.b64_encode(part)), part)
    end
    t.eq(lib.b64_encode("Man"), "TWFu")
    t.eq(lib.b64_encode("Ma"), "TWE=")
  end)

  t.it("seed_of and ts_name are stable", function()
    t.eq(lib.seed_of("get_project"), lib.seed_of("get_project"))
    t.ne(lib.seed_of("get_project"), lib.seed_of("get_projects"))
    t.eq(lib.ts_name("GetProject"), "getProject")
  end)
end)

t.describe("conform intended differences", function()
  local function split(category, case, diffs, extra)
    local result = { case = case, diffs = diffs }
    for k, v in pairs(extra or {}) do
      result[k] = v
    end
    local real, known = intended.split(category, result)
    return #real, #known
  end
  local resp = { response = { status = 404, body = '{"code":"E1","message":"m"}' } }

  t.it("status: only an absent Distilled status equal to the response's", function()
    t.same({ split("responses", resp, { { path = ".error.status", a = nil, b = 404 } }) }, { 0, 1 })
    t.same({ split("responses", resp, { { path = ".error.status", a = nil, b = 500 } }) }, { 1, 0 })
    t.same({ split("responses", resp, { { path = ".error.status", a = 404, b = 405 } }) }, { 1, 0 })
  end)

  t.it("code: Distilled 0 against the wire code or nil; absent against the wire code", function()
    t.same({ split("responses", resp, { { path = ".error.code", a = 0, b = "E1" } }) }, { 0, 1 })
    t.same({ split("responses", resp, { { path = ".error.code", a = 0, b = "E2" } }) }, { 1, 0 })
    t.same({ split("responses", resp, { { path = ".error.code", a = nil, b = "E1" } }) }, { 0, 1 })
    t.same({ split("responses", resp, { { path = ".error.code", a = "E1", b = nil } }) }, { 1, 0 })
  end)

  t.it("rules do not leak into the requests category", function()
    t.same({ split("requests", resp, { { path = ".error.status", a = nil, b = 404 } }) }, { 1, 0 })
  end)

  t.it("a missing label is intended only as that exact InvalidInput", function()
    local d = {
      path = "outcome",
      a = "request",
      b = "error InvalidInput: Input member project_id is required: it fills the path /p/{project_id}",
    }
    t.same({ split("requests", {}, { d }) }, { 0, 1 })
    t.same(
      {
        split(
          "requests",
          {},
          { { path = "outcome", a = "request", b = "error InvalidInput: other" } }
        ),
      },
      { 1, 0 }
    )
  end)

  t.it("parse error message only for a ParseError tag with an empty Distilled message", function()
    local got = { error = { tag = "NeonParseError" } }
    t.same(
      { split("responses", resp, { { path = ".error.message", a = "", b = "x" } }, { got = got }) },
      { 0, 1 }
    )
    t.same(
      { split("responses", resp, { { path = ".error.message", a = "y", b = "x" } }, { got = got }) },
      { 1, 0 }
    )
  end)
end)
