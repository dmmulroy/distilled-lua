-- S3 conformance: clients/s3 against Distilled's S3 client (packages/s3) on the cases in
-- spec/golden/s3/conform.lua (written by verify/lib/s3_conform.mjs): the signed request
-- of each operation (method, URL, headers and the SigV4 signature, body), the outcome of
-- canned responses (values and typed errors), and ListObjectsV2 pagination.
--
-- Intended differences are listed in INTENDED below, each with its reason
-- (verify/features/s3.md explains them).
local t = require("spec.harness")
local json = require("distilled.json")
local testing = require("distilled.testing")
local V = require("spec.golden.s3.conform")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local ok_load, S3 = t.pcall(function()
  return require("s3")
end)
local aws_credentials = ok_load and require("distilled.aws.credentials") or nil

-- Headers Distilled's HttpClient adds that the transport adds here (content-length) or
-- that name the SDK (user-agent).
local IGNORED_HEADERS = { ["user-agent"] = true, ["content-length"] = true }

-- Intended differences, by case id: a function(expected) that edits Distilled's result
-- into what clients/s3 does, with the reason.
local INTENDED = {
  -- Distilled sends an `x-amz-sdk-checksum-algorithm: SHA256` header without the
  -- checksum (it computes only CRC32 and MD5), which S3 refuses; we compute it.
  ["put-object-sha256"] = function(e)
    e.headers["x-amz-checksum-sha256"] = "Om6weQ85rIfJTzhWst0sXREOaBFgImGpqSPTuyOtyLc="
    e.headers.authorization = nil -- the checksum header is signed too
  end,
  -- A custom endpoint's trailing "/" is dropped here; Distilled keeps it and sends
  -- "//bucket/key", a different object key on S3-compatible stores.
  ["get-object-r2-endpoint"] = function(e)
    e.url = string.gsub(e.url, "%.com//", ".com/")
    e.headers.authorization = nil
  end,
}

-- Distilled's HttpBody.text gives a string body `content-type: text/plain` when no
-- member sets one (S3 stores it as the object's type); the Lua transport sends no
-- Content-Type then. Compared everywhere except that case.
local function drop_default_content_type(e, got)
  if e.headers["content-type"] == "text/plain" and got["content-type"] == nil then
    e.headers["content-type"] = nil
  end
end

-- `{ $date = s }` -> s, `{ $text = s }` -> s, `{ n = 0 }` -> {}
local function normalize(v)
  if type(v) ~= "table" then
    return v
  end
  if v["$date"] ~= nil then
    return v["$date"]
  end
  if v["$text"] ~= nil then
    return v["$text"]
  end
  if v.n == 0 and next(v, "n") == nil and next(v) == "n" then
    return {}
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = normalize(x)
  end
  return out
end

-- a Lua value as plain tables (json.null / array metatables dropped)
local function plain(v)
  if type(v) ~= "table" then
    return v
  end
  if v == json.null then
    return nil
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = plain(x)
  end
  return out
end

local function client_for(c, responses)
  local host = testing.host({ epoch = V.epoch, responses = responses })
  local client = S3.new({
    host = host,
    retry = "none",
    endpoint = c.endpoint,
    credentials = aws_credentials.static({
      access_key_id = V.access_key_id,
      secret_access_key = V.secret_access_key,
      session_token = c.session_token and V.session_token or nil,
      region = c.cred_region or "us-east-1",
    }),
  })
  return client, host
end

local function error_view(err)
  local cats = {}
  for k in pairs(err.categories or {}) do
    cats[#cats + 1] = k
  end
  table.sort(cats)
  return { tag = err.tag, message = err.message, categories = cats }
end

local function check_error(got_err, want, id)
  t.truthy(got_err, id .. ": an error")
  if not got_err then
    return
  end
  t.eq(got_err.tag, want.tag, id .. " tag")
  if want.message == "" or want.message == nil then
    -- no message on the wire: Distilled's is "", distilled.errors gives the tag
    t.truthy(got_err.message == want.tag or got_err.message == "", id .. " message")
  else
    t.eq(got_err.message, want.message, id .. " message")
  end
  if want.member then
    t.eq(got_err.member, want.member, id .. " member")
  end
  local view = error_view(got_err)
  t.same(view.categories, normalize(want.categories) or {}, id .. " categories")
  for k, v in pairs(want.fields or {}) do
    if k ~= "operation" and k ~= "service" then
      t.eq(got_err[k], v, id .. " field " .. k)
    end
  end
end

if not ok_load then
  t.pending("s3 conformance: clients/s3 not generated yet (" .. tostring(S3) .. ")")
  return
end

t.describe("s3 conformance: requests", function()
  for _, c in ipairs(V.requests) do
    t.it(c.id, function()
      local client, host = client_for(c, { { status = 200, body = "" } })
      local method = client[c.op]
      t.truthy(method, "operation " .. c.op)
      local _, err = method(client, normalize(c.input))
      local want = c.expected
      if not want.ok then
        check_error(err, want.error, c.id)
        t.eq(#host.requests, 0, "nothing sent")
        return
      end
      local req = host.requests[1]
      t.truthy(req, c.id .. ": a request was sent (" .. tostring(err and err.message) .. ")")
      if not req then
        return
      end
      local e = { method = want.method, url = want.url, headers = {}, body = want.body }
      for k, v in pairs(want.headers) do
        e.headers[k] = v
      end
      local got = {}
      for k, v in pairs(req.headers or {}) do
        got[string.lower(k)] = v
      end
      drop_default_content_type(e, got)
      if INTENDED[c.id] then
        INTENDED[c.id](e)
      end
      t.eq(req.method, e.method, "method")
      t.eq(req.url, e.url, "url")
      for k in pairs(IGNORED_HEADERS) do
        e.headers[k] = nil
        got[k] = nil
      end
      if e.headers.authorization == nil then
        got.authorization = nil
      end
      t.same(got, e.headers, "headers")
      local body = req.body
      if body == "" then
        body = nil
      end
      t.eq(body, e.body, "body")
    end)
  end
end)

t.describe("s3 conformance: responses", function()
  for _, c in ipairs(V.responses) do
    t.it(c.id, function()
      local client = client_for(c, { c.response })
      local value, err = client[c.op](client, normalize(c.input))
      local want = c.expected
      if want.ok then
        t.eq(err, nil, c.id .. ": " .. tostring(err and (err.tag .. " " .. tostring(err.message))))
        t.same(plain(value), normalize(want.value), c.id)
      else
        t.eq(value, nil, c.id .. ": no value")
        check_error(err, want.error, c.id)
      end
    end)
  end
end)

t.describe("s3 conformance: ListObjectsV2 pages", function()
  for _, c in ipairs(V.flows) do
    t.it(c.id, function()
      local client, host = client_for(c, c.responses)
      local pages = {}
      local it = client[c.op .. "_pages"](client, normalize(c.input))
      for page in it do
        pages[#pages + 1] = plain(page)
      end
      local last_err = it.err
      local want = c.expected
      t.eq(#host.requests, #want.sent, "requests")
      for i, s in ipairs(want.sent) do
        local r = host.requests[i]
        t.eq(r and r.method, s.method, "method " .. i)
        t.eq(r and r.url, s.url, "url " .. i)
      end
      t.same(pages, normalize(want.pages), "pages")
      if want.error then
        check_error(last_err, want.error, c.id)
      else
        t.eq(last_err, nil, "no error")
      end
    end)
  end
end)

t.describe("s3 conformance: presign_request (Presign.presignRequest)", function()
  local s3 = require("distilled.s3")
  for _, c in ipairs(V.presign_requests) do
    t.it(c.id, function()
      local client = client_for(c, {})
      local got, err = s3.presign_request(
        client,
        c.op,
        normalize(c.input),
        { expires_in = c.expires_in, datetime = "20231114T221320Z" }
      )
      local want = c.expected
      if want.ok then
        t.eq(err, nil, c.id .. ": " .. tostring(err and err.message))
        t.eq(got and got.method, want.value.method, "method")
        t.eq(got and got.url, want.value.url, "url")
        t.same(got and got.headers, normalize(want.value.headers), "headers")
      else
        t.eq(got, nil)
        check_error(err, want.error, c.id)
      end
    end)
  end
end)
