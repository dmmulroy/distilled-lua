local t = require("spec.harness")
local provider = require("distilled.gen.provider")
local fx = require("verify.lib.gen_fixture")

local function bad(overrides, pattern)
  local spec, err = provider.validate(fx.provider(overrides))
  t.eq(spec, nil)
  t.match(err, pattern, true)
end

t.describe("gen.provider: validation", function()
  t.it("accepts the fixture spec and normalizes it", function()
    local spec = provider.validate(fx.provider())
    t.eq(spec.name, "ex")
    t.eq(spec.base_url.default, "https://api.example.test/v1")
    t.eq(spec.base_url.option, "base_url")
    t.eq(spec.auth.kind, "bearer")
    t.eq(spec.naming.members, "wire")
    t.eq(spec.pagination.items_fallback, "items")
  end)

  t.it("accepts the plan's short form", function()
    local spec = provider.validate({
      name = "neon",
      base_url = "https://console.neon.tech/api/v2",
      auth = { kind = "bearer", from = "api_key", env = "NEON_API_KEY" },
      unknown_tag = "UnknownNeonError",
      parse_tag = "NeonParseError",
    })
    t.eq(spec.title, "Neon")
    t.eq(spec.base_url.default, "https://console.neon.tech/api/v2")
    t.eq(spec.base_url.option, "base_url")
  end)

  t.it("loads providers/neon.lua", function()
    local spec, err = provider.load(t.root .. "/providers/neon.lua")
    t.truthy(spec, err)
    t.eq(spec.auth.env, "NEON_API_KEY")
    t.eq(spec.base_url.env, "NEON_API_BASE_URL")
    t.eq(spec.unknown_tag, "UnknownNeonError")
    t.eq(spec.parse_tag, "NeonParseError")
  end)

  t.it("rejects unknown keys, naming them and the allowed ones", function()
    bad({ colour = "blue" }, "unknown key colour (allowed: allow_unsupported, auth, base_url")
    bad({ auth = { kind = "bearer", from = "api_key", token = "x" } }, "auth: unknown key token")
    bad({ naming = { member = "wire" } }, "naming: unknown key member")
  end)

  t.it("rejects a bad name, base URL and auth", function()
    bad({ name = "Ex" }, "name must be a lower-case Lua identifier")
    bad({ name = "end" }, "name must be a lower-case Lua identifier")
    bad({ base_url = "ftp://x" }, "base_url.default must be an http(s) URL")
    bad({ base_url = "https://x.test/" }, "must not end with /")
    bad({ auth = { kind = "digest" } }, "auth.kind must be bearer, header, basic or none")
    bad({ auth = { kind = "bearer" } }, "auth.from must name the client option")
    bad({ auth = { kind = "header", from = "api_key" } }, "auth.header must be a header name")
    bad({ auth = { kind = "bearer", from = "base_url" } }, "are the same option")
  end)

  t.it("rejects tags and envelope pointers that are not names and pointers", function()
    bad({ unknown_tag = "unknown error" }, "unknown_tag must be an error tag")
    bad({ parse_tag = "" }, "parse_tag must be an error tag")
    bad({ error_envelope = { code = "code" } }, "error_envelope.code must be a JSON pointer")
    bad({ error_envelope = { kind = "/k" } }, "error_envelope: unknown key kind")
    bad({ status_map = { [200] = "Ok" } }, "is not a 4xx/5xx status")
  end)

  t.it("refuses functions: only module names can be written into generated code", function()
    bad({ classify_error = function() end }, "must be a module name")
    bad({ protocol = function() end }, "must be a module name")
    local spec = provider.validate(fx.provider({ classify_error = "ex_extra.classify" }))
    t.eq(spec.classify_error, "ex_extra.classify")
  end)

  t.it("checks allow_unsupported against the known gaps", function()
    bad({ allow_unsupported = { "streaming" } }, "unknown gap streaming")
    -- the mechanism, with a gap a spec adds for the test (provider.UNSUPPORTED is empty
    -- since task 08 closed the multipart gap)
    provider.UNSUPPORTED.spec_gap = "a gap that exists only in this spec"
    local ok, spec = t.pcall(function()
      return provider.validate(fx.provider({ allow_unsupported = { "spec_gap" } }))
    end)
    provider.UNSUPPORTED.spec_gap = nil
    t.truthy(ok, tostring(spec))
    t.truthy(spec.allow_unsupported.spec_gap)
  end)

  t.it("a closed gap (multipart) in allow_unsupported is a stale spec", function()
    bad({ allow_unsupported = { "multipart" } }, "multipart is supported")
  end)

  t.it("reports a provider file that does not load", function()
    local spec, err = provider.load(t.root .. "/no/such/provider.lua")
    t.eq(spec, nil)
    t.match(err, "cannot read provider spec", true)
  end)
end)
