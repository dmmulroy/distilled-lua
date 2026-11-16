local t = require("spec.harness")
local redact = require("distilled.redact")
local S = require("distilled.schema")
local json = require("distilled.json")
local secret = require("distilled.secret")

local m = S.member

local function struct(members)
  return S.struct({ members = members })
end

-- Distilled sensitive.test.ts
t.describe("redact.holds_sensitive (sensitive.test.ts)", function()
  t.it("finds a secret in a member, a list element, a map value and a union arm", function()
    t.eq(
      redact.holds_sensitive(struct({ m({ name = "key", schema = S.string, sensitive = true }) })),
      true
    )
    t.eq(
      redact.holds_sensitive(
        struct({ m({ name = "keys", schema = S.list(S.sensitive(S.string)) }) })
      ),
      true
    )
    t.eq(
      redact.holds_sensitive(struct({ m({ name = "env", schema = S.map(S.sensitive(S.string)) }) })),
      true
    )
    t.eq(
      redact.holds_sensitive(struct({
        m({
          name = "auth",
          schema = S.union({
            struct({ m({ name = "token", schema = S.string, sensitive = true }) }),
            S.string,
          }),
        }),
      })),
      true
    )
    t.eq(
      redact.holds_sensitive(struct({
        m({ name = "name", schema = S.string }),
        m({ name = "tags", schema = S.list(S.string) }),
      })),
      false
    )
  end)

  t.it("a sensitive type holds a secret itself, also through a ref", function()
    t.eq(redact.holds_sensitive(S.sensitive(S.string)), true)
    t.eq(redact.holds_sensitive(S.ref("Token"), { Token = S.sensitive(S.string) }), true)
  end)

  t.it("answers for every type of a cycle, whichever is asked first", function()
    local reg = {
      A = struct({
        m({ name = "b", schema = S.ref("B") }),
        m({ name = "secret", schema = S.string, sensitive = true }),
      }),
      B = struct({ m({ name = "a", schema = S.ref("A") }) }),
    }
    t.eq(redact.holds_sensitive(reg.B, reg), true)
    t.eq(redact.holds_sensitive(reg.A, reg), true)
    t.eq(redact.holds_sensitive(S.ref("B"), reg), true)
  end)

  t.it("is cached per registry: the same ref differs between registries", function()
    local node = struct({ m({ name = "x", schema = S.ref("X") }) })
    t.eq(redact.holds_sensitive(node, { X = S.sensitive(S.string) }), true)
    t.eq(redact.holds_sensitive(node, { X = S.string }), false)
  end)

  t.it("a missing ref holds nothing", function()
    t.eq(redact.holds_sensitive(S.ref("Missing"), {}), false)
  end)
end)

t.describe("redact.plain (sensitive.test.ts)", function()
  t.it("withholds the whole plain form of a type that can hold a secret", function()
    local body = '{"name":"db","password":"fixture-password"}'
    local with_secret = struct({
      m({ name = "name", schema = S.string }),
      m({ name = "password", schema = S.string, sensitive = true }),
    })
    t.eq(redact.plain(with_secret, body), "[REDACTED]")
    t.eq(redact.plain(struct({ m({ name = "name", schema = S.string }) }), body), body)
    t.eq(redact.REDACTED, "[REDACTED]")
  end)

  t.it("judges input and output independently, each by its own schema", function()
    local In = struct({
      m({ name = "id", schema = S.string }),
      m({ name = "secret", schema = S.string, sensitive = true }),
    })
    local Out =
      struct({ m({ name = "id", schema = S.string }), m({ name = "version", schema = S.string }) })
    local output = { id = "db", version = "v-1" }
    t.eq(redact.parsed(Out, output), output)
    t.eq(redact.plain(Out, '{"id":"db"}'), '{"id":"db"}')
    t.eq(redact.plain(In, '{"id":"db"}'), "[REDACTED]")
  end)
end)

t.describe("redact.parsed (sensitive.test.ts)", function()
  local INPUT = struct({
    m({ name = "name", schema = S.string }),
    m({ name = "password", schema = S.string, sensitive = true }),
    m({ name = "key", schema = S.unknown, sensitive = true }),
    m({
      name = "credentials",
      schema = struct({
        m({ name = "id", schema = S.string }),
        m({ name = "secret", schema = S.string }),
      }),
      sensitive = true,
    }),
    m({ name = "env", schema = S.map(S.sensitive(S.string)) }),
    m({ name = "tokens", schema = S.list(S.sensitive(S.string)) }),
    m({ name = "count", schema = S.number, sensitive = true }),
  })

  t.it("redacts every sensitive value whole, of any type, and keeps the rest", function()
    local bytes = "\1\2\3"
    local wrapped = secret.wrap("fixture-wrapped")
    local out = redact.parsed(INPUT, {
      name = "db",
      password = "fixture-password",
      key = bytes,
      credentials = { id = "fixture-id", secret = "fixture-secret" },
      env = { API_KEY = "fixture-env", WRAPPED = wrapped },
      tokens = { "fixture-token" },
      count = 7,
    })
    t.eq(out.name, "db")
    t.eq(secret.unwrap(out.password), "fixture-password")
    t.eq(secret.unwrap(out.key), bytes)
    t.same(secret.unwrap(out.credentials), { id = "fixture-id", secret = "fixture-secret" })
    t.eq(secret.unwrap(out.env.API_KEY), "fixture-env")
    t.eq(out.env.WRAPPED, wrapped)
    t.eq(secret.unwrap(out.tokens[1]), "fixture-token")
    t.eq(secret.unwrap(out.count), 7)
    t.no_match(t.show(out), "fixture", true)
  end)

  t.it("returns a value with no secret type unchanged", function()
    local value = { name = "db" }
    t.eq(redact.parsed(struct({ m({ name = "name", schema = S.string }) }), value), value)
  end)
end)

-- Distilled protocol-http.test.ts "sensitive union responses" / "sensitive untyped members"
t.describe("redact.wrap (protocol-http.test.ts)", function()
  local UNION = S.union({
    struct({
      m({ name = "type", schema = S.enum({ "standard" }) }),
      m({ name = "password", schema = S.string, sensitive = true }),
    }),
    struct({
      m({ name = "type", schema = S.enum({ "token" }) }),
      m({ name = "token", schema = S.string, sensitive = true }),
    }),
    struct({ m({ name = "type", schema = S.enum({ "shared" }) }) }),
  })

  t.it("all arms redact their secrets, even in partial or ambiguous responses", function()
    for _, value in ipairs({
      { type = "standard", password = "fixture-password" },
      { type = "token", token = "fixture-token" },
      { password = "fixture-password", token = "fixture-token" },
    }) do
      local wrapped = redact.wrap(UNION, value)
      for k, v in pairs(value) do
        if k == "type" then
          t.eq(wrapped[k], v)
        else
          t.truthy(secret.is(wrapped[k]), k)
          t.eq(secret.unwrap(wrapped[k]), v)
        end
      end
      t.no_match(t.show(wrapped), "fixture", true)
      local again = redact.wrap(UNION, wrapped)
      for k, v in pairs(wrapped) do
        t.eq(again[k], v) -- idempotent: wrapped values are kept, not wrapped twice
      end
    end
  end)

  t.it("nested lists and nullable unions keep non-secret values", function()
    local nested = struct({
      m({ name = "provider", schema = UNION, nullable = true }),
      m({ name = "providers", schema = S.list(UNION) }),
    })
    for _, extra in ipairs({ {}, { provider = json.null }, { provider = { type = "shared" } } }) do
      local value = {
        providers = { { type = "standard", password = "fixture-password" }, { type = "shared" } },
      }
      for k, v in pairs(extra) do
        value[k] = v
      end
      local out = redact.wrap(nested, value)
      t.eq(out.providers[1].type, "standard")
      t.eq(secret.unwrap(out.providers[1].password), "fixture-password")
      t.same(out.providers[2], { type = "shared" })
      if extra.provider == json.null then
        t.eq(out.provider, json.null)
      elseif extra.provider then
        t.same(out.provider, { type = "shared" })
      else
        t.eq(out.provider, nil)
      end
      t.truthy(json.is_array(out.providers))
    end
  end)

  local UNTYPED = struct({
    m({ name = "environment", schema = S.unknown, sensitive = true, nullable = true }),
    m({
      name = "config",
      schema = struct({
        m({ name = "name", schema = S.string }),
        m({ name = "secret", schema = S.string, sensitive = true, nullable = true }),
      }),
      sensitive = true,
      nullable = true,
    }),
  })

  t.it("an untyped value is redacted whole; a typed struct is walked", function()
    local environment = { AWS_ACCESS_KEY_ID = "fixture-id", AWS_SECRET_ACCESS_KEY = "fixture-key" }
    local out = redact.wrap(
      UNTYPED,
      { environment = environment, config = { name = "files", secret = "fixture-secret" } }
    )
    t.truthy(secret.is(out.environment))
    t.eq(secret.unwrap(out.environment), environment)
    t.eq(out.config.name, "files")
    t.eq(secret.unwrap(out.config.secret), "fixture-secret")
    t.no_match(tostring(out.environment), "fixture", true)
    local again = redact.wrap(UNTYPED, out)
    t.eq(again.environment, out.environment)
    t.eq(again.config.secret, out.config.secret)
  end)

  t.it("null stays null", function()
    local out = redact.wrap(UNTYPED, { environment = json.null, config = json.null })
    t.eq(out.environment, json.null)
    t.eq(out.config, json.null)
  end)

  t.it(
    "only strings (and unknown values) are wrapped; a sensitive number stays readable",
    function()
      local node = struct({ m({ name = "pin", schema = S.number, sensitive = true }) })
      t.eq(redact.wrap(node, { pin = 1234 }).pin, 1234)
    end
  )

  t.it("keys the schema does not model pass through", function()
    local node = struct({ m({ name = "key", schema = S.string, sensitive = true }) })
    local out = redact.wrap(node, { key = "k", other = "o" })
    t.eq(out.other, "o")
    t.truthy(secret.is(out.key))
  end)

  t.it("wraps through maps, list items and refs", function()
    local reg = { Key = struct({ m({ name = "value", schema = S.string, sensitive = true }) }) }
    local node = struct({
      m({ name = "byName", schema = S.map(S.ref("Key")) }),
      m({ name = "list", schema = S.list(S.ref("Key")) }),
      m({ name = "tokens", schema = S.list(S.ref("Tok")) }),
    })
    reg.Tok = S.sensitive(S.string)
    local out = redact.wrap(node, {
      byName = { a = { value = "fixture-a" } },
      list = { { value = "fixture-b" } },
      tokens = { "fixture-c", json.null },
    }, reg)
    t.truthy(secret.is(out.byName.a.value))
    t.truthy(secret.is(out.list[1].value))
    t.truthy(secret.is(out.tokens[1]))
    t.eq(out.tokens[2], json.null)
    t.no_match(t.show(out), "fixture", true)
  end)

  t.it("a map arm skips keys a sibling struct arm names", function()
    local U = S.union({
      struct({ m({ name = "id", schema = S.string }) }),
      S.map(S.sensitive(S.string)),
    })
    local out = redact.wrap(U, { id = "visible", other = "hidden" })
    t.eq(out.id, "visible")
    t.truthy(secret.is(out.other))
  end)

  t.it("returns non-table values and values without secret types as they are", function()
    local node = struct({ m({ name = "key", schema = S.string, sensitive = true }) })
    t.eq(redact.wrap(node, "text"), "text")
    t.eq(redact.wrap(node, json.null), json.null)
    local v = { name = "x" }
    t.eq(redact.wrap(struct({ m({ name = "name", schema = S.string }) }), v), v)
  end)

  t.it("walks deep values without recursion", function()
    local reg = {
      N = struct({
        m({ name = "next", schema = S.ref("N") }),
        m({ name = "key", schema = S.string, sensitive = true }),
      }),
    }
    local root = {}
    local cur = root
    for _ = 1, 500 do
      cur.key = "fixture"
      cur.next = {}
      cur = cur.next
    end
    local out = redact.wrap(S.ref("N"), root, reg)
    local at, count = out, 0
    while at and at.key do
      t.truthy(secret.is(at.key))
      count = count + 1
      at = at.next
    end
    t.eq(count, 500)
  end)

  t.it("the fixture service wraps the api key member", function()
    local fixtures = require("distilled.testing.fixtures")
    local s = fixtures.service()
    local out = redact.wrap(s.ops.create_api_key.output, fixtures.bodies.api_key(), s.shapes)
    t.truthy(secret.is(out.key))
    t.eq(out.name, "ci")
    t.eq(redact.plain(s.ops.create_api_key.output, "{...}", s.shapes), "[REDACTED]")
    t.eq(redact.plain(s.ops.get_project.output, "{...}", s.shapes), "{...}")
  end)
end)
