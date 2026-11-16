local t = require("spec.harness")
local request = require("distilled.request")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")
local fixtures = require("distilled.testing.fixtures")

local m = S.member
local BASE = "https://example.test"

local function op(spec)
  spec.name = spec.name or "TestOp"
  return spec
end

local function build(o, input, extra)
  local args = { op = o, input = input, base_url = BASE }
  for k, v in pairs(extra or {}) do
    args[k] = v
  end
  return request.build(args)
end

-- Distilled protocol-http.test.ts "StringEncoded members"
local JSON_INPUT = op({
  method = "POST",
  uri = "/things",
  input = S.struct({
    members = {
      m({ name = "flag", schema = S.boolean, string_encoded = true }),
      m({ name = "plain", schema = S.boolean }),
      m({ name = "nullable", schema = S.boolean, nullable = true, string_encoded = true }),
      m({ name = "flags", schema = S.list(S.boolean), string_encoded = true }),
      m({
        name = "profile",
        schema = S.struct({
          members = {
            m({ name = "nested", wire = "nested_flag", schema = S.boolean, string_encoded = true }),
            m({ name = "plain", wire = "plain_flag", schema = S.boolean }),
          },
        }),
      }),
    },
  }),
})

t.describe("request: string_encoded members (protocol-http.test.ts)", function()
  t.it("booleans serialize as their string spelling", function()
    t.eq(build(JSON_INPUT, { flag = true, plain = true }).body, '{"flag":"true","plain":true}')
    t.eq(build(JSON_INPUT, { flag = false, plain = false }).body, '{"flag":"false","plain":false}')
  end)

  t.it("a list stringifies element-wise", function()
    t.eq(build(JSON_INPUT, { flags = { true, false } }).body, '{"flags":["true","false"]}')
  end)

  t.it("a member nested in a body struct stringifies too", function()
    t.eq(
      build(JSON_INPUT, { profile = { nested = true, plain = true } }).body,
      '{"profile":{"nested_flag":"true","plain_flag":true}}'
    )
  end)

  t.it("null stays null and an omitted member stays omitted", function()
    t.eq(build(JSON_INPUT, { nullable = json.null }).body, '{"nullable":null}')
    t.eq(build(JSON_INPUT, {}).body, "{}")
  end)
end)

t.describe("request: empty JSON bodies (protocol-http.test.ts)", function()
  local EMPTY =
    op({ method = "POST", uri = "/rpc.Service/List", input = S.struct({ members = {} }) })

  t.it("a POST with no body members sends no body by default", function()
    local r = build(EMPTY, {})
    t.eq(r.body, nil)
    t.eq(r.headers["content-type"], nil)
  end)

  t.it("empty_json_body sends {} as JSON", function()
    local r = build(EMPTY, {}, { empty_json_body = true })
    t.eq(r.body, "{}")
    t.eq(r.headers["content-type"], "application/json")
  end)

  t.it("an operation without an input schema behaves like an empty struct", function()
    local r = build(op({ method = "POST", uri = "/x" }), nil)
    t.eq(r.url, BASE .. "/x")
    t.eq(r.body, nil)
  end)

  local BODIED = op({
    method = "POST",
    uri = "/things",
    input = S.struct({ members = { m({ name = "name", schema = S.string }) } }),
  })

  t.it("a bodied method sends {} when body members are declared but unset", function()
    t.eq(build(BODIED, {}).body, "{}")
    local put = op({ method = "PUT", uri = "/things", input = BODIED.input })
    t.eq(build(put, {}).body, "{}")
  end)

  t.it("DELETE does not send {} for unset body members, but sends set ones", function()
    local del = op({ method = "DELETE", uri = "/things", input = BODIED.input })
    t.eq(build(del, {}).body, nil)
    t.eq(build(del, { name = "x" }).body, '{"name":"x"}')
  end)

  t.it("GET sends a body only when body members carry values", function()
    local get = op({ method = "GET", uri = "/things", input = BODIED.input })
    t.eq(build(get, {}).body, nil)
    local r = build(get, { name = "x" })
    t.eq(r.body, '{"name":"x"}')
    t.eq(r.headers["content-type"], "application/json")
    local head = op({ method = "HEAD", uri = "/things", input = BODIED.input })
    t.eq(build(head, {}).body, nil)
  end)
end)

t.describe("request: labels (protocol-http.test.ts)", function()
  local RUNTIME = op({
    method = "POST",
    uri = "/runtime/{scope}",
    input = S.struct({ members = { m({ name = "scope", bind = "label", schema = S.string }) } }),
  })

  t.it("labels are escaped like encodeURIComponent", function()
    t.eq(build(RUNTIME, { scope = "__KV:abc" }).url, BASE .. "/runtime/__KV%3Aabc")
    t.eq(
      build(RUNTIME, { scope = "__KV:a/b?c#d%3A\195\169" }).url,
      BASE .. "/runtime/__KV%3Aa%2Fb%3Fc%23d%253A%C3%A9"
    )
  end)

  t.it("number and boolean labels use their JavaScript spelling", function()
    t.eq(build(RUNTIME, { scope = 12 }).url, BASE .. "/runtime/12")
    t.eq(build(RUNTIME, { scope = 1.5 }).url, BASE .. "/runtime/1.5")
    t.eq(build(RUNTIME, { scope = true }).url, BASE .. "/runtime/true")
  end)

  local SCOPED = op({
    method = "GET",
    uri = "/{scope+}/providers/Things/{name}",
    input = S.struct({
      members = {
        m({ name = "scope", bind = "label", schema = S.string }),
        m({ name = "name", bind = "label", schema = S.string }),
      },
    }),
  })

  t.it("greedy: keeps slashes and drops the leading slash of the value", function()
    t.eq(
      build(SCOPED, { scope = "/subscriptions/abc/resourceGroups/my rg", name = "a/b" }).url,
      BASE .. "/subscriptions/abc/resourceGroups/my%20rg/providers/Things/a%2Fb"
    )
  end)

  t.it("greedy: accepts a value without a leading slash", function()
    t.eq(
      build(SCOPED, { scope = "subscriptions/abc", name = "x" }).url,
      BASE .. "/subscriptions/abc/providers/Things/x"
    )
  end)

  local DOTTED = op({
    method = "DELETE",
    uri = "/things/{id}",
    input = S.struct({ members = { m({ name = "id", bind = "label", schema = S.string }) } }),
  })

  t.it("a `.` or `..` label fails with InvalidInput before anything is built", function()
    for _, id in ipairs({ ".", ".." }) do
      local r, err = build(DOTTED, { id = id })
      t.fails_with("InvalidInput", r, err)
      t.eq(err.member, "id")
      t.match(err.message, "address another resource", true)
      t.truthy(err.categories.BadRequestError)
    end
  end)

  t.it("other dotted labels are sent as written", function()
    t.eq(build(DOTTED, { id = "..." }).url, BASE .. "/things/...")
    t.eq(build(DOTTED, { id = "a.b" }).url, BASE .. "/things/a.b")
  end)

  t.it("a greedy label is refused when any segment is . or ..", function()
    t.fails_with("InvalidInput", build(SCOPED, { scope = "a/../b", name = "x" }))
    t.fails_with("InvalidInput", build(SCOPED, { scope = "a/.", name = "x" }))
    t.eq(
      build(SCOPED, { scope = "a/.../b", name = "x" }).url,
      BASE .. "/a/.../b/providers/Things/x"
    )
  end)

  t.it("labels are refused before other members are read (a bad header does not win)", function()
    local o = op({
      method = "GET",
      uri = "/things/{id}",
      input = S.struct({
        members = {
          m({ name = "trace", bind = "header", schema = S.string }),
          m({ name = "id", bind = "label", schema = S.string }),
        },
      }),
    })
    local r, err = build(o, { trace = "a\nb", id = ".." })
    t.fails_with("InvalidInput", r, err)
    t.eq(err.member, "id")
  end)

  t.it("a missing label fails with InvalidInput instead of sending {id}", function()
    local r, err = build(DOTTED, {})
    t.fails_with("InvalidInput", r, err)
    t.eq(err.member, "id")
  end)

  t.it("a label with a wire name fills that placeholder", function()
    local o = op({
      method = "GET",
      uri = "/projects/{projectId}",
      input = S.struct({
        members = {
          m({ name = "project_id", wire = "projectId", bind = "label", schema = S.string }),
        },
      }),
    })
    t.eq(build(o, { project_id = "p 1" }).url, BASE .. "/projects/p%201")
  end)
end)

-- Distilled protocol-rest.test.ts "makeRestProtocol request encoding"
local THING = op({
  name = "CreateThing",
  method = "POST",
  uri = "/things/{id}",
  input = S.struct({
    members = {
      m({ name = "id", bind = "label", schema = S.string, required = true }),
      m({ name = "limit", bind = "query", schema = S.number }),
      m({ name = "tags", wire = "tag", bind = "query", schema = S.list(S.string) }),
      m({
        name = "states",
        wire = "state",
        bind = "query",
        schema = S.list(S.string),
        style = "comma",
      }),
      m({ name = "trace", wire = "X-Trace-Id", bind = "header", schema = S.string }),
      m({ name = "displayName", wire = "display_name", schema = S.string }),
      m({ name = "secret", wire = "secret_value", schema = S.string, sensitive = true }),
    },
  }),
})

t.describe("request: path, query, headers and body (protocol-rest.test.ts)", function()
  t.it("builds path, query, header and JSON body members from the input schema", function()
    local r = build(
      THING,
      { id = "a b/c", limit = 5, tags = { "x", "y" }, trace = "trace-1", displayName = "Widget" },
      {
        base_url = "https://api.test",
      }
    )
    t.eq(r.method, "POST")
    t.eq(r.url, "https://api.test/things/a%20b%2Fc?limit=5&tag=x&tag=y")
    t.eq(r.headers["x-trace-id"], "trace-1")
    t.eq(r.body, '{"display_name":"Widget"}')
    t.eq(r.headers["content-type"], "application/json")
  end)

  t.it("sends a comma-style query list as one comma-separated parameter", function()
    t.eq(
      build(THING, { id = "t1", states = { "running", "paused" } }).url,
      BASE .. "/things/t1?state=running%2Cpaused"
    )
  end)

  t.it("unwraps secret input values before serializing them", function()
    local r = build(THING, { id = "t1", secret = secret.wrap("s3cret") })
    t.eq(r.body, '{"secret_value":"s3cret"}')
  end)

  t.it("unwraps secrets in the base headers and lowercases their names", function()
    local r = build(
      THING,
      { id = "t1" },
      { headers = { Authorization = secret.wrap("Bearer tok-abc") } }
    )
    t.eq(r.headers.authorization, "Bearer tok-abc")
    t.eq(r.headers.Authorization, nil)
  end)

  t.it("map_member_header transforms member headers but not the base headers", function()
    local r = build(THING, { id = "t1", trace = "abc" }, {
      headers = { authorization = "Bearer tok-1" },
      map_member_header = function(name, value)
        return name .. "=" .. string.upper(value)
      end,
    })
    t.eq(r.headers["x-trace-id"], "x-trace-id=ABC")
    t.eq(r.headers.authorization, "Bearer tok-1")
  end)

  t.it("unknown_key_to_wire names input keys the schema does not model", function()
    local r = build(THING, { id = "t1", extraField = 1 }, {
      unknown_key_to_wire = function(key)
        return (
          string.gsub(key, "%u", function(c)
            return "_" .. string.lower(c)
          end)
        )
      end,
    })
    t.eq(r.body, '{"extra_field":1}')
  end)

  t.it("without unknown_key_to_wire, unmodeled input keys pass through verbatim", function()
    t.eq(build(THING, { id = "t1", extraField = 1 }).body, '{"extraField":1}')
  end)

  t.it("an unmodeled key on a GET still sends a body (it carries a value)", function()
    local s = fixtures.service()
    local r = request.build({
      op = s.ops.list_projects,
      input = { extra = 1 },
      registry = s.shapes,
      base_url = BASE,
    })
    t.eq(r.body, '{"extra":1}')
  end)

  t.it("a header value with a line break is refused", function()
    local r, err = build(THING, { id = "t1", trace = "a\r\nx-evil: 1" })
    t.fails_with("InvalidInput", r, err)
    t.eq(err.member, "trace")
  end)

  t.it("number and boolean query values use their JavaScript spelling", function()
    t.eq(build(THING, { id = "t", limit = 1.5 }).url, BASE .. "/things/t?limit=1.5")
    t.eq(build(THING, { id = "t", limit = 1e21 }).url, BASE .. "/things/t?limit=1e%2B21")
  end)

  t.it("query values are form-encoded like URLSearchParams", function()
    t.eq(
      build(THING, { id = "t", tags = { "a b", "c&d=e", "~" } }).url,
      BASE .. "/things/t?tag=a+b&tag=c%26d%3De&tag=%7E"
    )
  end)

  t.it("an empty list query sends nothing", function()
    t.eq(build(THING, { id = "t", tags = {} }).url, BASE .. "/things/t")
  end)

  t.it("json.null in a query is sent as the text null (Distilled's String(null))", function()
    t.eq(build(THING, { id = "t", limit = json.null }).url, BASE .. "/things/t?limit=null")
  end)
end)

t.describe("request: nested and deep query members", function()
  local FILTER = op({
    method = "GET",
    uri = "/dns_records",
    input = S.struct({
      members = {
        m({
          name = "name",
          bind = "query",
          schema = S.struct({
            members = {
              m({ name = "exact", schema = S.string }),
              m({ name = "contains", schema = S.string }),
            },
          }),
        }),
        m({
          name = "account",
          bind = "query",
          style = "deep",
          schema = S.struct({
            members = {
              m({ name = "account_id", wire = "id", schema = S.string }),
              m({ name = "tier", schema = S.string }),
            },
          }),
        }),
      },
    }),
  })

  t.it("a nested table goes dotted instead of [object Object]", function()
    t.eq(
      build(FILTER, { name = { exact = "a.example" } }).url,
      BASE .. "/dns_records?name.exact=a.example"
    )
    t.eq(
      build(FILTER, { name = { exact = "x", contains = "y" } }).url,
      BASE .. "/dns_records?name.contains=y&name.exact=x"
    )
  end)

  t.it("a deep member is renamed, expanded dotted, and skips nulls", function()
    t.eq(
      build(FILTER, { account = { account_id = "a1", tier = json.null } }).url,
      BASE .. "/dns_records?account.id=a1"
    )
  end)

  t.it("query_style brackets spells nested values a[b] and lists a[0]", function()
    local o = op({
      method = "GET",
      uri = "/v2/things",
      input = S.struct({
        members = {
          m({ name = "created", bind = "query", schema = S.map(S.number) }),
          m({ name = "expand", bind = "query", schema = S.list(S.string) }),
        },
      }),
    })
    local r = build(
      o,
      { created = { gte = 1 }, expand = { "a", "b" } },
      { query_style = "brackets" }
    )
    t.eq(r.url, BASE .. "/v2/things?created%5Bgte%5D=1&expand%5B0%5D=a&expand%5B1%5D=b")
  end)
end)

t.describe("request: bodies", function()
  local NESTED = op({
    method = "POST",
    uri = "/projects",
    input = S.struct({
      members = {
        m({
          name = "project",
          schema = S.struct({
            members = {
              m({ name = "name", schema = S.string }),
              m({ name = "allowed_ips", schema = S.list(S.string) }),
              m({ name = "labels", schema = S.map(S.string) }),
            },
          }),
        }),
      },
    }),
  })

  t.it("an empty list at a list node is sent as [] and an empty map as {}", function()
    t.eq(
      build(NESTED, { project = { allowed_ips = {}, labels = {} } }).body,
      '{"project":{"allowed_ips":[],"labels":{}}}'
    )
  end)

  t.it("json.null is sent as null; an absent key is omitted", function()
    t.eq(build(NESTED, { project = { name = json.null } }).body, '{"project":{"name":null}}')
  end)

  t.it("does not change the caller's tables (marks land on a copy)", function()
    local ips = {}
    local input = { project = { allowed_ips = ips } }
    build(NESTED, input)
    t.eq(getmetatable(ips), nil)
    t.eq(input.project.allowed_ips, ips)
  end)

  t.it("an unencodable body fails with InvalidInput, not a raise", function()
    local r, err = build(NESTED, { project = { name = 0 / 0 } })
    t.fails_with("InvalidInput", r, err)
    t.match(err.message, "TestOp", true)
  end)

  t.it("a cyclic input fails with InvalidInput", function()
    local cyc = {}
    cyc.self = cyc
    t.fails_with("InvalidInput", build(NESTED, { project = { labels = cyc } }))
  end)

  t.it("form-urlencoded bodies use bracket notation, members in declaration order", function()
    local o = op({
      method = "POST",
      uri = "/v1/customers",
      content_type = "form-urlencoded",
      input = S.struct({
        members = {
          m({ name = "name", schema = S.string }),
          m({ name = "shipping", schema = S.unknown }),
          m({ name = "expand", schema = S.list(S.string) }),
          m({ name = "skip", schema = S.string }),
        },
      }),
    })
    local r = build(o, {
      name = "A B",
      shipping = { address = { city = "Paris" } },
      expand = { "x", json.null, "y" },
      skip = json.null,
    })
    t.eq(r.body, "name=A+B&shipping%5Baddress%5D%5Bcity%5D=Paris&expand%5B0%5D=x&expand%5B2%5D=y")
    t.eq(r.headers["content-type"], "application/x-www-form-urlencoded")
  end)

  t.it("multipart operations fail with SdkError naming the operation", function()
    local o = op({
      name = "CreateDeployment",
      method = "POST",
      uri = "/d",
      content_type = "multipart",
      input = S.struct({ members = {} }),
    })
    local r, err = build(o, {})
    t.fails_with("SdkError", r, err)
    t.match(err.message, "CreateDeployment", true)
    t.match(err.message, "multipart", true)
  end)
end)

-- protocol-rest.test.ts "makeRestProtocol raw request bodies"
t.describe("request: payload members", function()
  local UPLOAD = op({
    method = "PUT",
    uri = "/objects/{key}",
    body_media_type = "application/octet-stream",
    input = S.struct({
      members = {
        m({ name = "key", bind = "label", schema = S.string }),
        m({ name = "body", bind = "payload", schema = S.string }),
        m({ name = "contentType", wire = "Content-Type", bind = "header", schema = S.string }),
      },
    }),
  })

  t.it("a raw body is sent under the caller's content-type", function()
    local r = build(UPLOAD, { key = "a.mp4", body = "\0\1\2#EXTM3U", contentType = "video/mp4" })
    t.eq(r.headers["content-type"], "video/mp4")
    t.eq(r.body, "\0\1\2#EXTM3U")
  end)

  t.it("without a content-type member value, the declared body_media_type is used", function()
    t.eq(
      build(UPLOAD, { key = "a.bin", body = "\1" }).headers["content-type"],
      "application/octet-stream"
    )
    local insert = op({
      method = "POST",
      uri = "/insert",
      body_media_type = "application/x-ndjson",
      input = S.struct({ members = { m({ name = "body", bind = "payload", schema = S.string }) } }),
    })
    local r = build(insert, { body = '{"id":"1"}\n' })
    t.eq(r.headers["content-type"], "application/x-ndjson")
    t.eq(r.body, '{"id":"1"}\n')
  end)

  t.it("a blob payload is sent as bytes (application/octet-stream by default)", function()
    local o = op({
      method = "PUT",
      uri = "/blob",
      input = S.struct({ members = { m({ name = "body", bind = "payload", schema = S.blob }) } }),
    })
    local r = build(o, { body = "\255\0" })
    t.eq(r.body, "\255\0")
    t.eq(r.headers["content-type"], "application/octet-stream")
  end)

  local PATCH = op({
    method = "PATCH",
    uri = "/things",
    input = S.struct({
      members = {
        m({ name = "body", bind = "payload", schema = S.unknown }),
        m({ name = "contentType", wire = "Content-Type", bind = "header", schema = S.string }),
      },
    }),
  })

  t.it("a JSON payload is sent under the content-type member, else as application/json", function()
    local merge = build(
      PATCH,
      { body = { spec = { replicas = 3 } }, contentType = "application/merge-patch+json" }
    )
    t.eq(merge.headers["content-type"], "application/merge-patch+json")
    t.eq(merge.body, '{"spec":{"replicas":3}}')
    local plain = build(PATCH, { body = { spec = { replicas = 3 } } })
    t.eq(plain.headers["content-type"], "application/json")
  end)

  t.it("a string payload without a media type is sent as a JSON string (as Distilled)", function()
    t.eq(build(PATCH, { body = "text" }).body, '"text"')
  end)

  t.it("a payload list is sent as a JSON array, an empty one as []", function()
    local o = op({
      method = "POST",
      uri = "/batch",
      input = S.struct({
        members = { m({ name = "items", bind = "payload", schema = S.list(S.string) }) },
      }),
    })
    t.eq(build(o, { items = { "a" } }).body, '["a"]')
    t.eq(build(o, { items = {} }).body, "[]")
  end)

  t.it("body fields go out under the content-type member; a set payload wins", function()
    local o = op({
      method = "PATCH",
      uri = "/things",
      input = S.struct({
        members = {
          m({ name = "contentType", wire = "Content-Type", bind = "header", schema = S.string }),
          m({ name = "spec", schema = S.unknown }),
          m({ name = "patch", bind = "payload", schema = S.unknown }),
        },
      }),
    })
    local merge =
      build(o, { contentType = "application/merge-patch+json", spec = { replicas = 3 } })
    t.eq(merge.headers["content-type"], "application/merge-patch+json")
    t.eq(merge.body, '{"spec":{"replicas":3}}')
    local jp = build(o, {
      contentType = "application/json-patch+json",
      patch = { { op = "replace", path = "/spec/replicas", value = 3 } },
    })
    t.eq(jp.headers["content-type"], "application/json-patch+json")
    t.eq(jp.body, '[{"op":"replace","path":"/spec/replicas","value":3}]')
  end)

  t.it("an unset payload on a bodied method sends {} (payload counts as a body member)", function()
    t.eq(build(PATCH, {}).body, "{}")
  end)
end)

t.describe("request: failures and misuse", function()
  t.it("an input that is not a table is InvalidInput", function()
    t.fails_with("InvalidInput", build(THING, "id"))
    t.fails_with("InvalidInput", build(THING, json.null))
    t.fails_with("InvalidInput", build(THING, json.array({ 1 })))
  end)

  t.it("a missing ref in the input schema is SdkError", function()
    local o = op({ method = "GET", uri = "/x", input = S.ref("Nope") })
    local r, err = request.build({ op = o, input = {}, registry = {} })
    t.fails_with("SdkError", r, err)
    t.match(err.message, "Nope", true)
  end)

  t.it("an input schema that is not a struct is SdkError", function()
    t.fails_with("SdkError", build(op({ method = "GET", uri = "/x", input = S.string }), {}))
  end)

  t.it("a wrong argument raises (misuse)", function()
    t.raises(function()
      request.build("x")
    end, "expected a table")
    t.raises(function()
      request.build({ op = {} })
    end, "op must be")
  end)

  t.it("errors never carry the secret input values", function()
    local r, err = build(THING, { id = "..", secret = secret.wrap("s3cret-CANARY") })
    t.fails_with("InvalidInput", r, err)
    t.no_match(t.show(err), "CANARY", true)
  end)
end)

t.describe("request: the fixture service", function()
  local s = fixtures.service()
  local function b(name, input)
    return request.build({
      op = s.ops[name],
      input = input,
      registry = s.shapes,
      base_url = fixtures.BASE_URL,
    })
  end

  t.it("get_project", function()
    local r = b("get_project", { project_id = "p 1" })
    t.eq(r.method, "GET")
    t.eq(r.url, fixtures.BASE_URL .. "/projects/p%201")
    t.eq(r.body, nil)
  end)

  t.it("list_projects", function()
    t.eq(
      b("list_projects", { limit = 10, cursor = "c/1" }).url,
      fixtures.BASE_URL .. "/projects?cursor=c%2F1&limit=10"
    )
  end)

  t.it("create_project resolves refs in the body", function()
    t.eq(
      b("create_project", { project = { name = "n", settings = { allowed_ips = {} } } }).body,
      '{"project":{"name":"n","settings":{"allowed_ips":[]}}}'
    )
  end)

  t.it("update_branch: two labels, a header, a renamed and a string-encoded member", function()
    local r = b(
      "update_branch",
      {
        project_id = "p",
        branch_id = "b",
        request_id = "r1",
        display_name = "x",
        protected = false,
      }
    )
    t.eq(r.url, fixtures.BASE_URL .. "/projects/p/branches/b")
    t.eq(r.headers["x-request-id"], "r1")
    t.eq(r.body, '{"name":"x","protected":"false"}')
  end)

  t.it("get_bucket_object: greedy label", function()
    t.eq(
      b("get_bucket_object", { project_id = "p", key = "/a b/c" }).url,
      fixtures.BASE_URL .. "/projects/p/objects/a%20b/c"
    )
  end)
end)
