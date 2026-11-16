-- Error shapes -> error class descriptors (`errors.define{ ... }` arguments).
--
-- Ports `errorCategories` from Distilled's generator.ts exactly, including its reading of
-- statuses: 404 is a BadRequestError there (the generated class), while core's built-in
-- NotFound carries NotFoundError. Matchers come from `com.distilled.openapi#errorMatchers`
-- as the model has them; every `matches` regex is compiled with `distilled.regex` here, so
-- a pattern the runtime cannot run fails generation instead of never matching.
local emit = require("distilled.gen.emit")
local json = require("distilled.json")
local naming = require("distilled.gen.naming")

local gen_errors = {}

-- core category.ts names (the set errors.define accepts)
gen_errors.CATEGORY_NAMES = {
  "AuthError",
  "BadRequestError",
  "ConflictError",
  "NotFoundError",
  "QuotaError",
  "ServerError",
  "ThrottlingError",
  "NetworkError",
  "ParseError",
  "ConfigurationError",
  "TimeoutError",
  "RetryableError",
  "LockedError",
  "AbortedError",
  "AlreadyExistsError",
  "DependencyViolationError",
}
local KNOWN = {}
for _, n in ipairs(gen_errors.CATEGORY_NAMES) do
  KNOWN[n] = true
end

local BAD_REQUEST = { [400] = true, [404] = true, [405] = true, [406] = true }
BAD_REQUEST[410], BAD_REQUEST[413], BAD_REQUEST[415], BAD_REQUEST[422] = true, true, true, true

--- gen_errors.categories(traits) -> list | nil, message   (Distilled's errorCategories)
function gen_errors.categories(traits, where)
  traits = traits or {}
  local out, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  local status = traits["smithy.api#httpError"]
  if type(status) == "number" then
    if status == 401 or status == 403 then
      add("AuthError")
    elseif status == 402 then
      add("QuotaError")
    elseif BAD_REQUEST[status] then
      add("BadRequestError")
    elseif status == 408 or status == 504 then
      add("TimeoutError")
    elseif status == 409 then
      add("ConflictError")
    elseif status == 429 then
      add("ThrottlingError")
    elseif status >= 500 and status < 600 then
      add("ServerError")
    end
  end
  local retryable = traits["smithy.api#retryable"]
  if retryable ~= nil then
    add("RetryableError")
    if type(retryable) == "table" and retryable.throttling == true then
      add("ThrottlingError")
    end
  end
  local declared = traits["distilled.errors#categories"]
  if declared ~= nil then
    local ok = type(declared) == "table"
    for _, name in ipairs(ok and declared or {}) do
      ok = ok and KNOWN[name] == true
    end
    if not ok then
      return nil,
        (where or "error")
          .. ": distilled.errors#categories must list categories from core category.ts ("
          .. table.concat(gen_errors.CATEGORY_NAMES, ", ")
          .. ")"
    end
    for _, name in ipairs(declared) do
      add(name)
    end
  end
  return out
end

local function check_text(where, v, problems)
  if type(v) == "string" then
    return v
  end
  if type(v) ~= "table" then
    problems[#problems + 1] = where .. " must be a string or { includes } / { matches }"
    return nil
  end
  local out = {}
  for k, x in pairs(v) do
    if k ~= "includes" and k ~= "matches" then
      problems[#problems + 1] = where .. " has unknown key " .. tostring(k)
    elseif type(x) ~= "string" then
      problems[#problems + 1] = where .. "." .. k .. " must be a string"
    else
      out[k] = x
    end
  end
  if out.matches then
    local regex = require("distilled.regex")
    local compiled, err = regex.compile(out.matches)
    if not compiled then
      problems[#problems + 1] = where
        .. ": the regex "
        .. string.format("%q", out.matches)
        .. " does not compile with distilled.regex: "
        .. tostring(err and err.message or err)
    end
  end
  if out.includes == nil and out.matches == nil then
    problems[#problems + 1] = where .. " needs includes or matches"
  end
  return out
end

-- An ErrorMatcher (core trait.ts): { code, status, message, body, headers }.
local function check_matcher(ctx, where, m, problems)
  if type(m) ~= "table" then
    problems[#problems + 1] = where .. " must be an object"
    return nil
  end
  local out = {}
  for _, k in ipairs(ctx.model:keys(m)) do
    local v = m[k]
    local at = where .. "." .. k
    if k == "status" or k == "code" then
      if type(v) ~= "number" then
        problems[#problems + 1] = at .. " must be a number"
      else
        out[k] = v
      end
    elseif k == "message" then
      out.message = check_text(at, v, problems)
    elseif k == "body" or k == "headers" then
      if type(v) ~= "table" then
        problems[#problems + 1] = at .. " must be an object"
      else
        local t = {}
        for _, key in ipairs(ctx.model:keys(v)) do
          local x = v[key]
          if k == "body" and string.sub(key, 1, 1) ~= "/" then
            problems[#problems + 1] = at .. ": key " .. key .. " is not a JSON pointer"
          end
          if k == "body" and (type(x) == "number" or type(x) == "boolean") then
            t[key] = x
          elseif k == "body" and x == json.null then
            t[key] = emit.raw("json.null")
            ctx.uses_json = true
          else
            t[key] = check_text(at .. "[" .. key .. "]", x, problems)
          end
        end
        out[k] = t
      end
    else
      problems[#problems + 1] = at .. ": unknown matcher key"
    end
  end
  return out
end

--- gen_errors.class(ctx, id) -> descriptor | nil, message
-- descriptor = { tag, categories, retryable, throttling, matchers, fields, doc, bodies }
function gen_errors.class(ctx, id)
  local def = ctx.model.shapes[id]
  local traits = def.traits or {}
  local problems = {}
  local cats, cerr = gen_errors.categories(traits, id)
  if not cats then
    return nil, cerr
  end
  local d = {
    tag = naming.local_name(id),
    categories = emit.list(cats),
    doc = traits["smithy.api#documentation"],
  }
  local retryable = traits["smithy.api#retryable"]
  if retryable ~= nil then
    d.retryable = true
    if type(retryable) == "table" and retryable.throttling == true then
      d.throttling = true
    end
  end
  local matchers = traits["com.distilled.openapi#errorMatchers"]
  if matchers ~= nil then
    if type(matchers) ~= "table" then
      return nil, id .. ": com.distilled.openapi#errorMatchers must be a list"
    end
    local list = {}
    for i, mm in ipairs(matchers) do
      list[i] = check_matcher(ctx, id .. " errorMatchers[" .. i .. "]", mm, problems)
    end
    d.matchers = emit.list(list)
  end
  -- Declared members become fields (the errors module fills them from the body, except
  -- the reserved instance field names). A shape with no members gets none: `code` and
  -- `message`, Distilled's default fields, are instance fields here already.
  local fields = {}
  for _, mem in ipairs(ctx.model:members(def)) do
    fields[#fields + 1] = require("distilled.gen.shapes").member_name(ctx, mem.name)
  end
  if #fields > 0 then
    d.fields = emit.list(fields)
  end
  if #problems > 0 then
    return nil, table.concat(problems, "\n")
  end
  return d
end

--- gen_errors.value(d) -> emit value for the errors.define argument
function gen_errors.value(d)
  return {
    tag = d.tag,
    categories = d.categories,
    retryable = d.retryable,
    throttling = d.throttling,
    matchers = d.matchers,
    fields = d.fields,
  }
end

--- gen_errors.statuses(ctx, id) -> statuses an error class stands for (errorStatuses)
function gen_errors.statuses(ctx, id)
  local traits = ctx.model.shapes[id].traits or {}
  local out, seen = {}, {}
  local function add(s)
    if type(s) == "number" and not seen[s] then
      seen[s] = true
      out[#out + 1] = s
    end
  end
  add(traits["smithy.api#httpError"])
  for _, m in ipairs(traits["com.distilled.openapi#errorMatchers"] or {}) do
    if type(m) == "table" then
      add(m.status)
    end
  end
  return out
end

return gen_errors
