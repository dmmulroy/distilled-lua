-- Credentials: sources, resolution, the client cache and refresh-on-401.
local t = require("spec.harness")
local credentials = require("distilled.credentials")
local errors = require("distilled.errors")
local json = require("distilled.json")
local secret = require("distilled.secret")
local Client = require("distilled.client")
local rest = require("distilled.protocol.rest")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")
local trace = require("distilled.trace")
local expect = require("distilled.testing.expect")

local CANARY = "sk-CANARY-cred-4242"

local function must(v, err)
  if v == nil then
    t.fail("expected a value, got " .. tostring(err))
  end
  return v
end

local function write_file(name, text)
  local path = t.root .. "/verify/tmp/" .. name
  local f = io.open(path, "wb")
  if not f then
    return nil
  end
  f:write(text)
  f:close()
  return path
end

t.describe("credentials.resolve", function()
  t.it("a string or a secret is the value, held as a secret", function()
    local v = must(credentials.resolve("k1", {}))
    t.truthy(secret.is(v))
    t.eq(secret.unwrap(v), "k1")
    local s = secret.wrap("k2")
    t.eq(secret.unwrap(must(credentials.resolve(s, {}))), "k2")
  end)

  t.it("a function is called with the host and its value wrapped", function()
    local host = { marker = true }
    local seen = {}
    local v = must(credentials.resolve(function(h)
      seen[1] = h
      return CANARY
    end, host))
    t.eq(seen[1], host)
    t.truthy(secret.is(v))
    t.eq(secret.unwrap(v), CANARY)
    -- a function may return a secret, or a table (several values)
    t.eq(
      secret.unwrap(must(credentials.resolve(function()
        return secret.wrap("x")
      end, host))),
      "x"
    )
    t.eq(
      secret.unwrap(must(credentials.resolve(function()
        return { token = "a", account = "b" }
      end, host))).account,
      "b"
    )
  end)

  t.it("nil, err passes an error table through; a message becomes ConfigError", function()
    local e = errors.new("Unauthorized", { message = "expired" })
    local _, got = credentials.resolve(function()
      return nil, e
    end, {})
    t.eq(got, e)
    local err = t.fails_with(
      "ConfigError",
      credentials.resolve(function()
        return nil, "vault sealed"
      end, {}, "api_key")
    )
    t.match(err.message, "vault sealed", true)
    t.eq(err.key, "api_key")
    t.fails_with("ConfigError", credentials.resolve(function() end, {}))
  end)

  t.it("a raise becomes SdkError; an empty value is ConfigError", function()
    local err = t.fails_with(
      "SdkError",
      credentials.resolve(function()
        error("boom")
      end, {})
    )
    t.match(err.message, "boom", true)
    t.fails_with("ConfigError", credentials.resolve("", {}))
    t.fails_with(
      "ConfigError",
      credentials.resolve(function()
        return ""
      end, {})
    )
  end)

  t.it("is_refreshable: only functions", function()
    t.truthy(credentials.is_refreshable(function() end))
    t.falsy(credentials.is_refreshable("x"))
    t.falsy(credentials.is_refreshable(secret.wrap("x")))
    t.truthy(credentials.is_source(secret.wrap("x")))
    t.falsy(credentials.is_source(42))
  end)
end)

t.describe("credentials.from_env / from_file / from_command", function()
  t.it("from_env reads host.getenv; unset and empty are ConfigError naming the variable", function()
    local src = credentials.from_env("NEON_API_KEY")
    t.eq(
      src({
        getenv = function(n)
          return n == "NEON_API_KEY" and "k" or nil
        end,
      }),
      "k"
    )
    local _, err = src({ getenv = function() end })
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "NEON_API_KEY", true)
    local _, err2 = src({
      getenv = function()
        return ""
      end,
    })
    t.eq(err2.tag, "ConfigError")
    t.raises(function()
      credentials.from_env("")
    end, "variable name")
  end)

  t.it("from_file trims trailing whitespace", function()
    local path = write_file("cred_spec_key.txt", CANARY .. "\n\n  \t")
    if not path then
      t.pending("verify/tmp is not writable")
      return
    end
    t.eq(credentials.from_file(path)(), CANARY)
    local spaced = write_file("cred_spec_spaced.txt", "  lead and inner  \r\n")
    t.eq(credentials.from_file(spaced)(), "  lead and inner")
    os.remove(path)
    os.remove(spaced)
  end)

  t.it(
    "from_file: missing or empty file is ConfigError, and the message never holds contents",
    function()
      local _, err = credentials.from_file(t.root .. "/verify/tmp/does-not-exist.key")()
      t.eq(err.tag, "ConfigError")
      t.match(err.message, "does-not-exist.key", true)
      local path = write_file("cred_spec_empty.txt", " \n")
      if path then
        local _, e2 = credentials.from_file(path)()
        t.eq(e2.tag, "ConfigError")
        os.remove(path)
      end
    end
  )

  t.it("from_command runs argv through host.exec and trims stdout", function()
    local seen = {}
    local host = {
      exec = function(argv, opts)
        seen.argv, seen.opts = argv, opts
        return { code = 0, ok = true, stdout = CANARY .. "\n", stderr = "" }
      end,
    }
    local v = credentials.from_command({ "op", "read", "op://vault/neon" }, { timeout = 5 })(host)
    t.eq(v, CANARY)
    t.same(seen.argv, { "op", "read", "op://vault/neon" })
    t.eq(seen.opts.timeout, 5)
  end)

  t.it("from_command fails with ConfigError when the host has no exec", function()
    local _, err = credentials.from_command({ "op" })({})
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "exec")
    t.match(err.message, "exec", true)
  end)

  t.it("from_command failures name the program and exit code, never the output", function()
    local function failing(res, msg)
      return {
        exec = function()
          return res, msg
        end,
      }
    end
    local src = credentials.from_command({ "op", "read" })
    local _, e1 = src(failing({ code = 2, ok = false, stdout = CANARY, stderr = CANARY }))
    t.eq(e1.tag, "ConfigError")
    t.match(e1.message, "code 2", true)
    t.no_match(e1.message, CANARY, true)
    local _, e2 = src(failing(nil, "not found"))
    t.match(e2.message, "not found", true)
    local _, e3 = src(failing({ code = nil, ok = false, timed_out = true }))
    t.match(e3.message, "timed out", true)
    local _, e4 = src(failing({ code = 0, ok = true, stdout = "\n" }))
    t.match(e4.message, "printed nothing", true)
    t.raises(function()
      credentials.from_command("op read")
    end, "argv")
  end)
end)

---------------------------------------------------------------------------------------
-- through a client
---------------------------------------------------------------------------------------

local function neon_class()
  local service = fixtures.service()
  service.telemetry = { system = "neon-api", prefix = "Neon", service = "Neon" }
  service.ops.get_project.span = "GetProject"
  return Client.define({
    service = service,
    protocol = rest.new({
      base_url = function(c)
        return c.base_url
      end,
      headers = function(c)
        -- the resolved value reaches the protocol as a secret
        if not secret.is(c.api_key) then
          error("api_key is not a secret")
        end
        return { authorization = "Bearer " .. secret.unwrap(c.api_key) }
      end,
    }),
    options = {
      api_key = { secret = true, env = "NEON_API_KEY", required = true },
      base_url = { default = fixtures.BASE_URL, env = "NEON_BASE_URL" },
    },
  })
end
local Neon = neon_class()

local function ok_project()
  return { body = fixtures.bodies.project("p1") }
end

t.describe("credentials: the client cache", function()
  t.it("a function source is resolved on first use and cached", function()
    local calls = { n = 0 }
    local host = testing.host({ responses = { ok_project(), ok_project() } })
    local c = Neon.new({
      host = host,
      api_key = function()
        calls.n = calls.n + 1
        return "k" .. calls.n
      end,
    })
    t.eq(calls.n, 0)
    must(c:get_project({ project_id = "p1" }))
    must(c:get_project({ project_id = "p1" }))
    t.eq(calls.n, 1)
    t.eq(host.requests[2].headers.authorization, "Bearer k1")
  end)

  t.it("derived clients share the cache unless they override the option", function()
    local calls = { n = 0 }
    local host = testing.host({ responses = { ok_project(), ok_project(), ok_project() } })
    local c = Neon.new({
      host = host,
      api_key = function()
        calls.n = calls.n + 1
        return "k" .. calls.n
      end,
    })
    must(c:get_project({ project_id = "p1" }))
    must(c:with({ validation = "strict" }):get_project({ project_id = "p1" }))
    t.eq(calls.n, 1)
    must(c:with({ api_key = "other" }):get_project({ project_id = "p1" }))
    t.eq(host.requests[3].headers.authorization, "Bearer other")
    t.eq(calls.n, 1)
  end)

  t.it(
    "without a value the env variable named by the option is read through host.getenv",
    function()
      local host = testing.host({
        responses = { ok_project() },
        env = { NEON_API_KEY = "from-env", NEON_BASE_URL = "https://eu.test/v2" },
      })
      must(Neon.new({ host = host }):get_project({ project_id = "p1" }))
      t.eq(host.requests[1].headers.authorization, "Bearer from-env")
      t.eq(host.requests[1].url, "https://eu.test/v2/projects/p1")
    end
  )

  t.it(
    "a missing required option fails the call with ConfigError naming option and variable",
    function()
      local host = testing.host({})
      local err =
        t.fails_with("ConfigError", Neon.new({ host = host }):get_project({ project_id = "p1" }))
      t.eq(err.key, "api_key")
      t.match(err.message, "NEON_API_KEY", true)
      t.eq(#host.requests, 0)
      local Bare = Client.define({
        service = fixtures.service(),
        protocol = rest.new({ base_url = "https://x.test" }),
        options = { token = { secret = true, required = true } },
      })
      local e2 = t.fails_with(
        "ConfigError",
        Bare.new({ host = testing.host({}) }):get_project({ project_id = "p1" })
      )
      t.eq(e2.key, "token")
      t.match(e2.message, "token is required", true)
    end
  )

  t.it("an optional secret that is absent leaves the header out", function()
    local Opt = Client.define({
      service = fixtures.service(),
      protocol = rest.new({ base_url = fixtures.BASE_URL, headers = rest.bearer("token") }),
      options = { token = { secret = true, env = "TOKEN" } },
    })
    local host = testing.host({ responses = { ok_project() } })
    must(Opt.new({ host = host }):get_project({ project_id = "p1" }))
    t.eq(host.requests[1].headers.authorization, nil)
  end)

  t.it("option values are checked in new", function()
    t.raises(function()
      Neon.new({ api_key = 42 })
    end, "api_key must be a string, a secret or a function")
  end)
end)

t.describe("credentials: refresh on Unauthorized", function()
  local function unauthorized()
    return { status = 401, body = { message = "token expired" } }
  end

  t.it("clears the cache, resolves once more and retries the call a single time", function()
    local calls = { n = 0 }
    local memory = trace.exporters.memory()
    local host = testing.host({ responses = { unauthorized(), ok_project() } })
    local tracer = trace.new({ level = "debug", exporter = memory, host = host })
    local c = Neon.new({
      host = host,
      tracer = tracer,
      api_key = function()
        calls.n = calls.n + 1
        return "token-" .. calls.n
      end,
    })
    must(c:get_project({ project_id = "p1" }))
    t.eq(calls.n, 2)
    t.eq(#host.requests, 2)
    t.eq(host.requests[1].headers.authorization, "Bearer token-1")
    t.eq(host.requests[2].headers.authorization, "Bearer token-2")
    local e = expect(memory.spans)
    e:span("Neon.GetProject"):ok():attr("distilled.credentials.refreshed", true)
    e:spans("distilled.attempt"):count(2)
    e:spans("distilled.credentials"):count(2)
    e:no_attr_contains("token-1")
    e:no_attr_contains("token-2")
  end)

  t.it("a second Unauthorized is returned: one refresh only", function()
    local calls = { n = 0 }
    local host = testing.host({ responses = { unauthorized(), unauthorized(), ok_project() } })
    local c = Neon.new({
      host = host,
      api_key = function()
        calls.n = calls.n + 1
        return "t" .. calls.n
      end,
    })
    t.fails_with("Unauthorized", c:get_project({ project_id = "p1" }))
    t.eq(#host.requests, 2)
    t.eq(calls.n, 2)
    -- the next call starts from the cache the refresh filled
    must(c:get_project({ project_id = "p1" }))
    t.eq(calls.n, 2)
  end)

  t.it("a fixed string or secret is never refreshed", function()
    for _, key in ipairs({ "fixed", secret.wrap("fixed") }) do
      local host = testing.host({ responses = { unauthorized() } })
      t.fails_with(
        "Unauthorized",
        Neon.new({ host = host, api_key = key }):get_project({ project_id = "p1" })
      )
      t.eq(#host.requests, 1)
    end
  end)

  t.it("the env fallback is a function source, so it is refreshed (rotated key)", function()
    local env = { NEON_API_KEY = "old" }
    local host = testing.host({ responses = { unauthorized(), ok_project() }, env = env })
    local c = Neon.new({ host = host })
    host.transport.responses[1] = function()
      env.NEON_API_KEY = "new"
      return unauthorized()
    end
    must(c:get_project({ project_id = "p1" }))
    t.eq(host.requests[2].headers.authorization, "Bearer new")
  end)

  t.it("a refresh that fails returns the refresh failure", function()
    local calls = { n = 0 }
    local host = testing.host({ responses = { unauthorized() } })
    local c = Neon.new({
      host = host,
      api_key = function()
        calls.n = calls.n + 1
        if calls.n > 1 then
          return nil, "vault sealed"
        end
        return "k"
      end,
    })
    local err = t.fails_with("ConfigError", c:get_project({ project_id = "p1" }))
    t.match(err.message, "vault sealed", true)
    t.eq(#host.requests, 1)
  end)
end)

t.describe("credentials: secrets stay out of errors and traces", function()
  t.it("an Unauthorized error, its tostring and a debug trace do not hold the key", function()
    local memory = trace.exporters.memory()
    local host = testing.host({ responses = { { status = 401, body = { message = "bad key" } } } })
    local tracer = trace.new({ level = "debug", exporter = memory, host = host })
    local _, err = Neon.new({ host = host, tracer = tracer, api_key = CANARY })
      :get_project({ project_id = "p1" })
    t.eq(err.tag, "Unauthorized")
    t.no_match(tostring(err), CANARY, true)
    t.no_match(json.encode({ m = err.message, b = err.body, h = err.headers }) or "", CANARY, true)
    expect(memory.spans):no_attr_contains(CANARY)
  end)
end)
