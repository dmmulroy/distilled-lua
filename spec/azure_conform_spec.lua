-- Azure conformance: the generated clients (clients/azure) against what Distilled's
-- TypeScript SDK did, saved in spec/golden/azure/ref.json by verify/lib/azure_ref.mjs
-- (`verify/dl azure-ref`; the request cases come from verify/lib/azure_cases.lua).
-- Runs in every runtime.
--
-- Compared: for each of the 1,170 request cases (every model, the first operation of
-- each HTTP method and with a greedy label, a header, a query or a payload member) the
-- method, the URL byte for byte, every header Distilled sends but content-length, and
-- the body (JSON by value); for each response case the outcome (the value, or the
-- error's tag, categories, retryable, throttling and every field Distilled's error has);
-- and the error module (classes, code map, message matchers in order).
--
-- Intended differences (verify/features/azure.md): Lua errors from an HTTP failure also
-- carry `status`, `body`, `headers` (and `code` on a status-map class); a message
-- Distilled leaves undefined (it prints "") is `HTTP <status>`; a parse error's message
-- says what failed (Distilled: "").
local t = require("spec.harness")
local compat = require("distilled.compat")
local json = require("distilled.json")
local secret = require("distilled.secret")
local azure_errors = require("distilled.azure.errors")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local ref = json.decode(assert(read(t.root .. "/spec/golden/azure/ref.json")))
local cases = json.decode(assert(read(t.root .. "/spec/fixtures/azure/cases.json")))

local function enc(v)
  return (json.encode(v))
end

-- a client of `model` whose transport records the request and answers `response`
local function client(model, response, validation)
  local Class = require("azure." .. model)
  local sent = {}
  local host = {
    transport = function(req)
      sent[#sent + 1] = req
      return {
        status = response and response.status or 200,
        headers = response and response.headers or {},
        body = response and response.body or "{}",
      }
    end,
    getenv = function()
      return nil
    end,
    sleep = function() end,
    epoch = function()
      return 1700000000
    end,
  }
  return Class.new({
    host = host,
    retry = "none",
    bearer_token = ref.token,
    subscription_id = ref.subscription,
    api_base_url = ref.base_url,
    validation = validation,
  }),
    sent
end

-- JSON-able view of a decoded value, as the Node script views Distilled's
local function view(v)
  if secret.is(v) then
    return { ["$redacted"] = view(secret.unwrap(v)) }
  end
  if type(v) ~= "table" or v == json.null then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = view(x)
  end
  return setmetatable(out, getmetatable(v))
end

t.describe("azure conformance: requests (spec/golden/azure/ref.json)", function()
  local by_id = {}
  for _, r in ipairs(ref.requests) do
    by_id[r.id] = r
  end
  local models, by_model = {}, {}
  for _, c in ipairs(cases) do
    if not by_model[c.model] then
      by_model[c.model] = {}
      models[#models + 1] = c.model
    end
    local list = by_model[c.model]
    list[#list + 1] = c
  end

  t.it("has a Distilled request for every case, and every one built", function()
    t.eq(#ref.requests, #cases)
    for _, c in ipairs(cases) do
      local r = by_id[c.id]
      t.truthy(r, c.id)
      t.truthy(r.ok, c.id .. " built in Distilled")
    end
  end)

  for _, model in ipairs(models) do
    t.it(model .. ": method, URL, headers and body match Distilled", function()
      local problems = {}
      local function bad(id, what, got, want)
        problems[#problems + 1] = id
          .. ": "
          .. what
          .. "\n    lua:  "
          .. tostring(got)
          .. "\n    ts:   "
          .. tostring(want)
      end
      for _, c in ipairs(by_model[model]) do
        local want = by_id[c.id]
        local cl, sent = client(model)
        local _, err = cl[c.method](cl, c.input)
        local req = sent[1]
        if req == nil then
          bad(
            c.id,
            "no request",
            err and (tostring(err.tag) .. ": " .. tostring(err.message)),
            want.url
          )
        else
          if req.method ~= want.method then
            bad(c.id, "method", req.method, want.method)
          end
          if req.url ~= want.url then
            bad(c.id, "url", req.url, want.url)
          end
          for name, value in pairs(want.headers) do
            if name ~= "content-length" and req.headers[name] ~= value then
              bad(c.id, "header " .. name, req.headers[name], value)
            end
          end
          for name in pairs(req.headers) do
            if want.headers[name] == nil and name ~= "user-agent" then
              bad(c.id, "extra header " .. name, req.headers[name], nil)
            end
          end
          local body = req.body
          if want.body.kind == "none" then
            if body ~= nil and body ~= "" then
              bad(c.id, "body", body, "(none)")
            end
          else
            local a, b = json.decode(body or ""), json.decode(want.body.text)
            if a == nil or b == nil then
              if body ~= want.body.text then
                bad(c.id, "body bytes", body, want.body.text)
              end
            elseif enc(a) ~= enc(b) then
              bad(c.id, "body", enc(a), enc(b))
            end
          end
        end
      end
      if #problems > 0 then
        t.fail(#problems .. " mismatches:\n  " .. compat.concat(problems, "\n  "))
      end
    end)
  end
end)

-- the Lua error as the Node script views a Distilled error; fields Distilled's error
-- lacks may be extra (ALLOWED_EXTRA), every field it has must match
local ALLOWED_EXTRA = { status = true, code = true, body = true, headers = true }
local function error_matches(lua_err, want)
  local cats = {}
  for k in pairs(lua_err.categories or {}) do
    cats[#cats + 1] = k
  end
  table.sort(cats)
  local want_cats = {}
  for _, c in ipairs(want.categories) do
    want_cats[c] = true
  end
  local got = {
    tag = lua_err.tag,
    categories = enc(json.array(cats)),
    retryable = lua_err.retryable == true,
    -- Distilled's isThrottling: the retryable trait's flag or the ThrottlingError category
    throttling = lua_err.throttling == true,
    status = lua_err.status,
    code = lua_err.code,
    message = lua_err.message,
    target = lua_err.target,
    retry_after = lua_err.retry_after,
    body = lua_err.body ~= nil and enc(view(lua_err.body)) or nil,
  }
  local expect = {
    tag = want.tag,
    categories = enc(json.array(want.categories)),
    retryable = want.retryable,
    throttling = want.throttling or want_cats.ThrottlingError == true,
    status = want.status,
    code = want.code,
    message = want.message,
    target = want.target,
    retry_after = want.retry_after,
    body = want.body ~= nil and enc(want.body) or nil,
  }
  local problems = {}
  for _, k in ipairs({
    "tag",
    "categories",
    "retryable",
    "throttling",
    "status",
    "code",
    "message",
    "target",
    "retry_after",
    "body",
  }) do
    local g, w = got[k], expect[k]
    if g ~= w then
      local intended = (w == nil and ALLOWED_EXTRA[k])
        -- a message Distilled leaves undefined ("") is HTTP <status> here
        or (k == "message" and w == "" and g == "HTTP " .. tostring(lua_err.status))
        -- a parse error's message says what failed
        or (k == "message" and w == "" and lua_err.tag == "AzureParseError")
      if not intended then
        problems[#problems + 1] = k .. ": lua " .. tostring(g) .. ", ts " .. tostring(w)
      end
    end
  end
  return problems
end

t.describe("azure conformance: responses", function()
  for _, c in ipairs(ref.responses) do
    t.it(c.id .. " (" .. c.model .. "." .. c.method .. " " .. c.status .. ")", function()
      local cl = client(c.model, {
        status = c.status,
        headers = c.headers or {},
        body = c.body ~= json.null and c.body or "",
      }, c.validation)
      local value, err = cl[c.method](cl, c.input)
      local want = c.outcome
      if want.ok then
        t.eq(err, nil, "no error")
        t.eq(enc(view(value)), enc(want.value))
      else
        t.eq(value, nil)
        t.truthy(err, "an error")
        local problems = error_matches(err, want.error)
        if #problems > 0 then
          t.fail(compat.concat(problems, "; "))
        end
      end
    end)
  end
end)

t.describe("azure conformance: the error module", function()
  t.it("every Distilled class exists with its categories, retryable flag and fields", function()
    local n = 0
    for tag, want in pairs(ref.errors.classes) do
      n = n + 1
      local class = azure_errors.classes[tag]
      t.truthy(class, tag)
      local cats = {}
      for k in pairs(class.categories) do
        cats[#cats + 1] = k
      end
      table.sort(cats)
      t.eq(enc(json.array(cats)), enc(json.array(want.categories)), tag)
      t.eq(class.retryable, want.retryable, tag .. " retryable")
      local has_target = false
      for _, f in ipairs(want.fields) do
        has_target = has_target or f == "target"
      end
      t.eq(class.fields[1] == "target", has_target, tag .. " target")
    end
    t.eq(n, 182)
  end)

  t.it("the code map is Distilled's AZURE_ERROR_CODE_MAP", function()
    local n = 0
    for code, tag in pairs(ref.errors.codes) do
      n = n + 1
      t.eq(azure_errors.codes[code] and azure_errors.codes[code].tag, tag, code)
    end
    local m = 0
    for _ in pairs(azure_errors.codes) do
      m = m + 1
    end
    t.eq(m, n)
  end)

  t.it("the message matchers are Distilled's, in order", function()
    t.eq(#azure_errors.matchers, #ref.errors.matchers)
    for i, want in ipairs(ref.errors.matchers) do
      local m = azure_errors.matchers[i]
      t.eq(m.code, want.code, "matcher " .. i .. " code")
      t.eq(m.includes, want.includes, "matcher " .. i)
      t.eq(m.class.tag, want.tag, "matcher " .. i .. " tag")
    end
  end)
end)
