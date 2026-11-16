local t = require("spec.harness")
local errors = require("distilled.errors")
local json = require("distilled.json")

t.describe("errors classes and instances", function()
  t.it("defines a class and builds an instance from it", function()
    local Gone = errors.define({
      tag = "Gone",
      categories = { "NotFoundError" },
      matchers = { { status = 410 } },
      fields = { "reason" },
    })
    t.truthy(errors.is_class(Gone))
    local err = errors.new(Gone, { message = "bye", status = 410, reason = "deleted" })
    t.truthy(errors.is(err))
    t.eq(err.tag, "Gone")
    t.eq(err.message, "bye")
    t.eq(err.status, 410)
    t.eq(err.reason, "deleted")
    t.same(err.categories, { NotFoundError = true })
    t.eq(err.retryable, false)
    t.eq(err.throttling, false)
  end)

  t.it("instances get their own copy of the category set", function()
    local a = errors.new("NotFound", {})
    a.categories.Extra = true
    t.eq(errors.new("NotFound", {}).categories.Extra, nil)
  end)

  t.it("tostring is 'Tag: message', with the trace id when set", function()
    local err = errors.new("NotFound", { message = "no project p1" })
    t.eq(tostring(err), "NotFound: no project p1")
    err.trace_id = "abc123"
    t.eq(tostring(err), "NotFound: no project p1 [trace abc123]")
  end)

  t.it("defaults the message to HTTP <status>, else to the tag", function()
    t.eq(errors.new("BadGateway", { status = 502 }).message, "HTTP 502")
    t.eq(errors.new("SdkError").message, "SdkError")
  end)

  t.it("a tag string finds the built-in class, or makes a plain one", function()
    local err = errors.new("TooManyRequests", { message = "slow" })
    t.eq(err.retryable, true)
    t.eq(err.throttling, true)
    local custom = errors.new("UnknownNeonError", { status = 402, code = "PAY" })
    t.eq(custom.tag, "UnknownNeonError")
    t.same(custom.categories, {})
    t.eq(custom.code, "PAY")
  end)

  t.it("keeps a cause", function()
    local inner = errors.new("TransportError", { message = "curl: (6) could not resolve host" })
    local outer = errors.new("SdkError", { message = "wrapped", cause = inner })
    t.eq(outer.cause, inner)
  end)

  t.it("rejects misuse with raised errors", function()
    t.raises(function()
      errors.define({ tag = "X", categories = { "NoSuchCategory" } })
    end, "unknown category")
    t.raises(function()
      errors.define({})
    end, "tag")
    t.raises(function()
      errors.new(42)
    end, "expected an error class")
  end)
end)

t.describe("errors predicates", function()
  t.it("is, is_tag, has_category", function()
    local err = errors.new("Forbidden", { message = "no" })
    t.truthy(errors.is(err))
    t.falsy(errors.is({ tag = "Forbidden" }))
    t.falsy(errors.is("Forbidden"))
    t.truthy(errors.is_tag(err, "Forbidden"))
    t.falsy(errors.is_tag(err, "NotFound"))
    t.truthy(errors.has_category(err, "AuthError"))
    t.falsy(errors.has_category(err, "NotFoundError"))
    t.falsy(errors.has_category(nil, "AuthError"))
  end)

  t.it("is_transient follows isTransientError", function()
    t.truthy(errors.is_transient(errors.new("TransportError", {})), "NetworkError")
    t.truthy(errors.is_transient(errors.new("TooManyRequests", {})), "throttling")
    t.truthy(errors.is_transient(errors.new("InternalServerError", {})), "retryable")
    t.truthy(errors.is_transient(errors.new("Locked", {})), "retryable")
    t.falsy(errors.is_transient(errors.new("NotFound", {})))
    t.falsy(errors.is_transient(errors.new("UnknownError", {})))
    -- a category that only describes an error does not make it retryable
    local Described = errors.define({
      tag = "Described",
      categories = { "ServerError", "TimeoutError", "LockedError" },
    })
    t.falsy(errors.is_transient(errors.new(Described, {})))
    local Marked = errors.define({ tag = "Marked", categories = { "RetryableError" } })
    t.truthy(errors.is_transient(errors.new(Marked, {})))
    t.falsy(errors.is_transient(nil))
  end)

  t.it("is_throttling follows isThrottling", function()
    t.truthy(errors.is_throttling(errors.new("TooManyRequests", {})))
    t.falsy(errors.is_throttling(errors.new("ServiceUnavailable", {})))
    -- not retryable: the ThrottlingError category decides
    local CatOnly = errors.define({ tag = "CatOnly", categories = { "ThrottlingError" } })
    t.truthy(errors.is_throttling(errors.new(CatOnly, {})))
    -- retryable without throttling = true: the retryable mark decides, even with the category
    local Plain =
      errors.define({ tag = "Plain", categories = { "ThrottlingError" }, retryable = true })
    t.falsy(errors.is_throttling(errors.new(Plain, {})))
    t.falsy(errors.new(Plain, {}).throttling)
  end)
end)

t.describe("errors built-ins", function()
  t.it("has the sixteen categories of category.ts", function()
    t.eq(#errors.CATEGORIES, 16)
    t.eq(errors.CATEGORIES[1], "AuthError")
    t.eq(errors.CATEGORIES[16], "DependencyViolationError")
  end)

  t.it("built-in classes carry errors.ts categories and retry marks", function()
    local expected = {
      BadRequest = { "BadRequestError", false, false },
      Unauthorized = { "AuthError", false, false },
      Forbidden = { "AuthError", false, false },
      NotFound = { "NotFoundError", false, false },
      Conflict = { "ConflictError", false, false },
      UnprocessableEntity = { "BadRequestError", false, false },
      Locked = { "LockedError", true, false },
      TooManyRequests = { "ThrottlingError", true, true },
      InternalServerError = { "ServerError", true, false },
      BadGateway = { "ServerError", true, false },
      ServiceUnavailable = { "ServerError", true, false },
      GatewayTimeout = { "ServerError", true, false },
      ConfigError = { "ConfigurationError", false, false },
      InvalidInput = { "BadRequestError", false, false },
      ParseError = { "ParseError", false, false },
      TransportError = { "NetworkError", false, false },
    }
    for tag, want in pairs(expected) do
      local class = errors.classes[tag]
      t.truthy(class, tag)
      t.eq(errors[tag], class, tag)
      local cats = {}
      cats[want[1]] = true
      t.same(class.categories, cats, tag)
      t.eq(class.retryable, want[2], tag .. " retryable")
      t.eq(class.throttling, want[3], tag .. " throttling")
    end
    t.same(errors.SdkError.categories, {})
    t.same(errors.UnknownError.categories, {})
  end)

  t.it("STATUS_MAP is HTTP_STATUS_MAP", function()
    local want = {
      [400] = "BadRequest",
      [401] = "Unauthorized",
      [403] = "Forbidden",
      [404] = "NotFound",
      [408] = "GatewayTimeout",
      [409] = "Conflict",
      [422] = "UnprocessableEntity",
      [423] = "Locked",
      [429] = "TooManyRequests",
      [500] = "InternalServerError",
      [502] = "BadGateway",
      [503] = "ServiceUnavailable",
      [504] = "GatewayTimeout",
    }
    local n = 0
    for status, class in pairs(errors.STATUS_MAP) do
      n = n + 1
      t.eq(class.tag, want[status], tostring(status))
    end
    t.eq(n, 13)
  end)
end)

-- The classes protocol-rest.test.ts declares, as Lua classes.
local ThingLocked = errors.define({
  tag = "ThingLocked",
  matchers = { { status = 409, message = { includes = "locked" } } },
})
local QuotaExceeded = errors.define({ tag = "QuotaExceeded", matchers = { { code = 4001 } } })
local QuotaExceededOnCreate =
  errors.define({ tag = "QuotaExceededOnCreate", matchers = { { code = 4001, status = 403 } } })
local Teapot = errors.define({
  tag = "Teapot",
  matchers = { { status = 418, headers = { ["X-Reason"] = "teapot" } } },
})
local Gone =
  errors.define({ tag = "Gone", matchers = { { body = { ["/detail/kind"] = "gone" } } } })
local Nested = errors.define({
  tag = "Nested",
  matchers = { { status = 412 } },
  fields = { "status", "details", "requestId" },
})
local SlowDown = errors.define({
  tag = "SlowDown",
  matchers = { { status = 409, body = { ["/code"] = "slow_down" } } },
  fields = { "retry_after" },
})
local KeyReused = errors.define({
  tag = "KeyReused",
  matchers = { { status = 422, body = { ["/code"] = "key_reused" } } },
  fields = { "code", "requestId", "error" },
})
local DECLARED = { ThingLocked, QuotaExceeded, QuotaExceededOnCreate, Teapot, Gone }

local function body(text)
  return (json.decode(text))
end

t.describe("errors.match (protocol-rest typed error matching)", function()
  t.it("a declared error whose status and message matcher match wins", function()
    local err = errors.match(
      DECLARED,
      { status = 409, message = "thing is locked", body = body('{"message":"thing is locked"}') }
    )
    t.eq(err.tag, "ThingLocked")
    t.eq(err.message, "thing is locked")
    t.eq(err.status, 409)
  end)

  t.it("a numeric envelope code selects the declared error with that code", function()
    local err = errors.match(DECLARED, { status = 400, code = 4001, message = "quota" })
    t.eq(err.tag, "QuotaExceeded")
    t.eq(err.message, "quota")
    t.eq(err.code, 4001)
  end)

  t.it("the most specific matching declared error wins", function()
    t.eq(
      errors.match(DECLARED, { status = 403, code = 4001, message = "quota" }).tag,
      "QuotaExceededOnCreate"
    )
  end)

  t.it("a string envelope code never satisfies a numeric code matcher", function()
    t.eq(errors.match(DECLARED, { status = 400, code = "4001", message = "quota" }), nil)
  end)

  t.it(
    "header matchers see headers case-insensitively; body and headers reach the error",
    function()
      local b = body('{"message":"short and stout"}')
      local err = errors.match(DECLARED, {
        status = 418,
        message = "short and stout",
        body = b,
        headers = { ["x-reason"] = "teapot" },
      })
      t.eq(err.tag, "Teapot")
      t.same(err.body, { message = "short and stout" })
      t.eq(err.headers["x-reason"], "teapot")
    end
  )

  t.it("header values are case-sensitive and missing headers never match", function()
    t.eq(errors.match({ Teapot }, { status = 418, headers = { ["x-reason"] = "TEAPOT" } }), nil)
    t.eq(errors.match({ Teapot }, { status = 418 }), nil)
    t.eq(errors.match({ Teapot }, { status = 418, headers = {} }), nil)
  end)

  t.it("body pointer matchers see the parsed JSON body", function()
    local err = errors.match(
      DECLARED,
      { status = 410, message = "bye", body = body('{"message":"bye","detail":{"kind":"gone"}}') }
    )
    t.eq(err.tag, "Gone")
  end)

  t.it("declared fields carry the body's values, with the matched code and message", function()
    local b = body(
      '{"code":"key_reused","message":"key was used","requestId":"req_1","error":{"details":{"window":"day"}},"extra":true}'
    )
    local err = errors.match({ KeyReused }, { status = 422, message = "key was used", body = b })
    t.eq(err.tag, "KeyReused")
    t.eq(err.requestId, "req_1")
    t.same(err.error, { details = { window = "day" } })
    -- Distilled sets code to 0 here (`best.code ?? 0`); the Lua contract says nil when
    -- the wire error had no numeric code. The body's string code never wins.
    t.eq(err.code, nil)
    t.eq(err.message, "key was used")
    t.eq(err.extra, nil)
  end)

  t.it("declared errors are ignored when nothing matches", function()
    t.eq(errors.match(DECLARED, { status = 409, message = "thing is busy" }), nil)
    t.eq(errors.match({}, { status = 409, message = "thing is locked" }), nil)
  end)

  t.it("fields_at reads declared fields from the nested object, then the top level", function()
    local b = body(
      '{"error":{"message":"no","status":"FAILED_PRECONDITION","details":[1]},"requestId":"r"}'
    )
    local err = errors.match(
      { Nested, SlowDown },
      { status = 412, message = "no", body = b, fields_at = "/error" }
    )
    t.eq(err.tag, "Nested")
    t.same(err.details, { 1 })
    t.truthy(json.is_array(err.details))
    t.eq(err.requestId, "r")
    -- `status` is reserved for the HTTP status; a declared `status` field is not copied
    t.eq(err.status, 412)
  end)

  t.it("a class that declares retry_after gets the caller's parsed hint; others do not", function()
    local b = body('{"code":"slow_down","message":"later"}')
    local err = errors.match(
      { SlowDown },
      { status = 409, message = "later", body = b, retry_after = 7 }
    )
    t.eq(err.tag, "SlowDown")
    t.eq(err.retry_after, 7)
    local other = errors.match(
      { ThingLocked },
      { status = 409, message = "locked", retry_after = 7 }
    )
    t.eq(other.retry_after, nil)
  end)

  t.it("a non-JSON error body can still be matched by a message matcher", function()
    local text = "resource locked by another op"
    local err = errors.match(DECLARED, { status = 409, message = text, body = text })
    t.eq(err.tag, "ThingLocked")
    t.eq(err.message, text)
    t.eq(err.body, text)
  end)

  t.it("without code or message the wire message is HTTP <status>", function()
    local C = errors.define({ tag = "C", matchers = { { message = "HTTP 503" } } })
    local err = errors.match({ C }, { status = 503 })
    t.eq(err.tag, "C")
    t.eq(err.message, "HTTP 503")
  end)

  t.it("ties break by declaration order", function()
    local A = errors.define({ tag = "A", matchers = { { status = 400 } } })
    local B = errors.define({ tag = "B", matchers = { { status = 400 } } })
    t.eq(errors.match({ A, B }, { status = 400 }).tag, "A")
    t.eq(errors.match({ B, A }, { status = 400 }).tag, "B")
  end)

  t.it("tries every wire error when several are given", function()
    local err = errors.match(DECLARED, {
      status = 400,
      errors = { { code = 1, message = "first" }, { code = 4001, message = "second" } },
    })
    t.eq(err.tag, "QuotaExceeded")
    t.eq(err.message, "second")
    t.eq(err.code, 4001)
  end)

  t.it("an unconstrained matcher matches nothing", function()
    local Empty =
      errors.define({ tag = "Empty", matchers = { {}, { body = {} }, { headers = {} } } })
    t.eq(errors.match({ Empty }, { status = 400, message = "x", body = {} }), nil)
  end)

  -- task 03 replaced the "never matches" placeholder with distilled.regex
  t.it("a text matcher with `matches` tests the JavaScript regex (task 03)", function()
    local R =
      errors.define({ tag = "R", matchers = { { status = 409, message = { matches = "^lock" } } } })
    local RI = errors.define({
      tag = "RI",
      matchers = { { status = 409, message = { includes = "lock", matches = "lock" } } },
    })
    t.eq(errors.match({ R, RI }, { status = 409, message = "locked" }).tag, "R")
    t.eq(errors.match({ R, RI }, { status = 409, message = "unlocked" }).tag, "RI")
    t.eq(errors.match({ R, RI }, { status = 409, message = "open" }), nil)
  end)

  t.it("an empty includes matcher matches any string", function()
    local I = errors.define({ tag = "I", matchers = { { message = { includes = "" } } } })
    t.eq(errors.match({ I }, { status = 400, message = "anything" }).tag, "I")
  end)

  t.it("rejects a non-class in the list", function()
    t.raises(function()
      errors.match({ "NotFound" }, { status = 404 })
    end, "error classes")
  end)
end)

t.describe("errors body pointers", function()
  local doc = body(
    '{"a":{"b":"x","n":5,"t":true,"z":null},"items":[{"kind":"k0"},{"kind":"k1"}],"a/b":"slash","m~n":"tilde","":"empty"}'
  )

  t.it("follows objects and 0-based array indices", function()
    t.eq(errors.at_pointer(doc, "/a/b"), "x")
    t.eq(errors.at_pointer(doc, "/items/0/kind"), "k0")
    t.eq(errors.at_pointer(doc, "/items/1/kind"), "k1")
    t.eq(errors.at_pointer(doc, "/items/2/kind"), nil)
    t.eq(errors.at_pointer(doc, ""), doc)
    t.eq(errors.at_pointer(doc, "/"), "empty")
  end)

  t.it("rejects malformed indices and pointers", function()
    t.eq(errors.at_pointer(doc, "/items/01/kind"), nil)
    t.eq(errors.at_pointer(doc, "/items/-1"), nil)
    t.eq(errors.at_pointer(doc, "/items/kind"), nil)
    t.eq(errors.at_pointer(doc, "a/b"), nil)
    t.eq(errors.at_pointer(doc, "/m~2n"), nil)
    t.eq(errors.at_pointer(doc, "/m~"), nil)
  end)

  t.it("unescapes ~1 and ~0", function()
    t.eq(errors.at_pointer(doc, "/a~1b"), "slash")
    t.eq(errors.at_pointer(doc, "/m~0n"), "tilde")
  end)

  t.it("returns json.null for a present null and nil for a missing member", function()
    t.eq(errors.at_pointer(doc, "/a/z"), json.null)
    t.eq(errors.at_pointer(doc, "/a/missing"), nil)
    t.eq(errors.at_pointer(doc, "/a/z/deeper"), nil)
    t.eq(errors.at_pointer(doc, "/a/b/deeper"), nil)
  end)

  t.it("body matchers: null matches a present null only; strings never match null", function()
    local IsNull =
      errors.define({ tag = "IsNull", matchers = { { body = { ["/a/z"] = json.null } } } })
    local MissingNull =
      errors.define({ tag = "MissingNull", matchers = { { body = { ["/a/q"] = json.null } } } })
    local StrNull =
      errors.define({ tag = "StrNull", matchers = { { body = { ["/a/z"] = "null" } } } })
    local IncNull =
      errors.define({ tag = "IncNull", matchers = { { body = { ["/a/z"] = { includes = "" } } } } })
    local info = { status = 400, body = doc }
    t.eq(errors.match({ IsNull }, info).tag, "IsNull")
    t.eq(errors.match({ MissingNull }, info), nil)
    t.eq(errors.match({ StrNull }, info), nil)
    t.eq(errors.match({ IncNull }, info), nil)
  end)

  t.it("body matchers compare numbers and booleans by value and type", function()
    local Num =
      errors.define({ tag = "Num", matchers = { { body = { ["/a/n"] = 5, ["/a/t"] = true } } } })
    local NumStr = errors.define({ tag = "NumStr", matchers = { { body = { ["/a/n"] = "5" } } } })
    local False = errors.define({ tag = "False", matchers = { { body = { ["/a/t"] = false } } } })
    local info = { status = 400, body = doc }
    t.eq(errors.match({ Num }, info).tag, "Num")
    t.eq(errors.match({ NumStr }, info), nil)
    t.eq(errors.match({ False }, info), nil)
  end)

  t.it("each body pointer and header adds a specificity point", function()
    t.eq(
      errors.matcher_specificity({
        status = 1,
        body = { ["/a"] = 1, ["/b"] = 2 },
        headers = { x = "y" },
      }),
      4
    )
    local One = errors.define({ tag = "One", matchers = { { status = 400 } } })
    local Two =
      errors.define({ tag = "Two", matchers = { { body = { ["/a/b"] = "x", ["/a/n"] = 5 } } } })
    t.eq(errors.match({ One, Two }, { status = 400, body = doc }).tag, "Two")
  end)

  t.it("a body that is not a table never satisfies a pointer", function()
    t.eq(errors.match({ Gone }, { status = 410, body = "detail kind gone" }), nil)
    t.eq(errors.match({ Gone }, { status = 410, body = json.null }), nil)
    t.eq(errors.match({ Gone }, { status = 410 }), nil)
  end)
end)
