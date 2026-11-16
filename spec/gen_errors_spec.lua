local t = require("spec.harness")
local gen_errors = require("distilled.gen.errors")
local errors = require("distilled.errors")
local fx = require("verify.lib.gen_fixture")

t.describe("gen.errors: errorCategories (Distilled generator.ts)", function()
  local CASES = {
    { 401, { "AuthError" } },
    { 403, { "AuthError" } },
    { 402, { "QuotaError" } },
    { 400, { "BadRequestError" } },
    { 404, { "BadRequestError" } },
    { 405, { "BadRequestError" } },
    { 406, { "BadRequestError" } },
    { 410, { "BadRequestError" } },
    { 413, { "BadRequestError" } },
    { 415, { "BadRequestError" } },
    { 422, { "BadRequestError" } },
    { 408, { "TimeoutError" } },
    { 504, { "TimeoutError" } },
    { 409, { "ConflictError" } },
    { 429, { "ThrottlingError" } },
    { 500, { "ServerError" } },
    { 503, { "ServerError" } },
    { 418, {} },
  }
  for _, c in ipairs(CASES) do
    t.it("httpError " .. c[1], function()
      t.same(gen_errors.categories({ ["smithy.api#httpError"] = c[1] }), c[2])
    end)
  end

  t.it("no httpError, no categories", function()
    t.same(gen_errors.categories({}), {})
  end)

  t.it("retryable adds RetryableError, and ThrottlingError when throttling", function()
    t.same(gen_errors.categories({ ["smithy.api#retryable"] = {} }), { "RetryableError" })
    t.same(
      gen_errors.categories({ ["smithy.api#retryable"] = { throttling = true } }),
      { "RetryableError", "ThrottlingError" }
    )
    t.same(
      gen_errors.categories({
        ["smithy.api#httpError"] = 503,
        ["smithy.api#retryable"] = {},
      }),
      { "ServerError", "RetryableError" }
    )
  end)

  t.it("distilled.errors#categories adds declared categories, without duplicates", function()
    t.same(
      gen_errors.categories({
        ["smithy.api#httpError"] = 409,
        ["distilled.errors#categories"] = { "AlreadyExistsError", "ConflictError" },
      }),
      { "ConflictError", "AlreadyExistsError" }
    )
    local cats, err =
      gen_errors.categories({ ["distilled.errors#categories"] = { "NoSuchError" } }, "ex.api#X")
    t.eq(cats, nil)
    t.match(err, "ex.api#X: distilled.errors#categories must list categories from core", true)
  end)

  t.it("every category name is one errors.define accepts", function()
    for _, name in ipairs(gen_errors.CATEGORY_NAMES) do
      errors.define({ tag = "Probe", categories = { name } })
    end
  end)
end)

t.describe("gen.errors: generated classes", function()
  local files = assert(fx.generate())
  local svc = fx.load(files["service.lua"], "ex.service")

  t.it("defines a class per error the selected operations name", function()
    t.truthy(errors.is_class(svc.errors.NotFound))
    t.truthy(errors.is_class(svc.errors.Throttled))
    t.same(svc.errors.NotFound.categories, { BadRequestError = true })
    t.same(svc.errors.NotFound.matchers, { { status = 404 } })
  end)

  t.it("carries retryable, throttling, matchers with regexes, declared fields", function()
    local c = svc.errors.Throttled
    t.eq(c.retryable, true)
    t.eq(c.throttling, true)
    t.same(c.fields, { "retry_hint" })
    t.same(c.matchers, { { status = 429, message = { matches = "^slow( down)?$" } } })
  end)

  t.it("service errors are inherited by every operation, after its own", function()
    t.same(svc.ops.get_thing.errors, { "NotFound", "Throttled" })
    t.same(svc.ops.list_things.errors, { "Throttled" })
  end)

  t.it("the generated matchers match through errors.match", function()
    local classes = { svc.errors.NotFound, svc.errors.Throttled }
    local e = errors.match(classes, { status = 429, message = "slow down" })
    t.eq(e.tag, "Throttled")
    e = errors.match(classes, { status = 429, message = "other" })
    t.eq(e, nil)
    e = errors.match(classes, { status = 404, message = "gone" })
    t.eq(e.tag, "NotFound")
  end)
end)

t.describe("gen.errors: refusals", function()
  t.it("a regex distilled.regex cannot compile fails generation", function()
    local files, err = fx.generate({ replace = { { '"^slow( down)?$"', '"(?<=slow)down"' } } })
    t.eq(files, nil)
    t.match(err, "ex.api#Throttled errorMatchers[1].message", true)
    t.match(err, "does not compile with distilled.regex", true)
  end)

  t.it("an unknown matcher key fails generation", function()
    local _, err =
      fx.generate({ replace = { { '[{ "status": 404 }]', '[{ "status": 404, "kind": "x" }]' } } })
    t.match(err, "errorMatchers[1].kind: unknown matcher key", true)
  end)

  t.it("a body matcher key must be a JSON pointer; null is kept as json.null", function()
    local _, err = fx.generate({
      replace = { { '[{ "status": 404 }]', '[{ "status": 404, "body": { "code": "x" } }]' } },
    })
    t.match(err, "key code is not a JSON pointer", true)
    local files = assert(fx.generate({
      replace = { { '[{ "status": 404 }]', '[{ "status": 404, "body": { "/error": null } }]' } },
    }))
    t.match(files["service.lua"], 'local json = require("distilled.json")', true)
    local svc = fx.load(files["service.lua"], "ex.service")
    t.eq(svc.errors.NotFound.matchers[1].body["/error"], require("distilled.json").null)
  end)

  t.it("an error tag equal to the provider's unknown or parse tag fails", function()
    local _, err = fx.generate({ provider = fx.provider({ unknown_tag = "NotFound" }) })
    t.match(err, "error tag NotFound is the provider's unknown_tag", true)
  end)
end)
