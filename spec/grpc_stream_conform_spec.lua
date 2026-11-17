-- Streams against Distilled's TS (task 30): spec/golden/grpc_stream/conform.json holds
-- what packages/boxd (core protocol-grpc.ts streamReply) and packages/e2b (connect.ts)
-- do with canned streamed replies; the Lua clients must send the same request bytes and
-- deliver the same items and errors. Regenerate the golden file with
--   node --conditions=bun --experimental-transform-types --no-warnings \
--     verify/lib/grpc_stream_conform.mjs spec/golden/grpc_stream/conform.json
local t = require("spec.harness")
local json = require("distilled.json")
local errors = require("distilled.errors")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local b64 = require("distilled.crypto.base64")
local stub = require("spec.grpc_stream_stub")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function read(path)
  local f = assert(io.open(t.root .. "/" .. path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local golden = json.decode(read("spec/golden/grpc_stream/conform.json"))

-- the request headers both sides set on purpose (not traceparent, b3, user-agent)
local HEADERS = {
  "authorization",
  "content-type",
  "x-grpc-web",
  "te",
  "connect-protocol-version",
  "e2b-sandbox-id",
  "e2b-sandbox-port",
  "x-access-token",
}

local function reply_of(c)
  local chunks = {}
  for i, piece in ipairs(c.reply.chunks) do
    chunks[i] = assert(b64.decode(piece))
  end
  return { status = c.reply.status, headers = c.reply.headers, chunks = chunks }
end

-- a Lua item in the golden file's JSON shape (bytes as { bytes_b64 })
local function view(item)
  local out = {}
  for k, v in pairs(item) do
    if secret.is(v) then
      v = secret.unwrap(v)
    end
    if k == "data" and item._tag ~= nil then
      out[k] = { bytes_b64 = b64.encode(v) }
    else
      out[k] = v
    end
  end
  return out
end

local function check_request(c, req)
  local sent = c.sent[1]
  t.eq(req.method, sent.method)
  t.eq(req.url, sent.url)
  for _, h in ipairs(HEADERS) do
    local mine = req.headers[h]
    if mine ~= nil then
      mine = tostring(secret.is(mine) and secret.unwrap(mine) or mine)
    end
    t.eq(mine, sent.headers[h], h)
  end
  t.eq(b64.encode(req.body), sent.body_b64)
end

local function check_outcome(c, items, err)
  t.eq(#items, #c.items, c.name .. ": item count")
  for i, item in ipairs(items) do
    t.eq(json.encode(view(item)), json.encode(c.items[i]), c.name .. ": item " .. i)
  end
  if c.error == nil then
    t.eq(err, nil, c.name .. ": no error")
    return
  end
  t.truthy(errors.is(err), c.name .. ": an error")
  t.eq(err.tag, c.error.tag, c.name .. ": tag")
  -- TS leaves some messages empty (an UnknownE2BError without one, E2BParseError)
  if c.error.message ~= nil and c.error.message ~= "" then
    t.eq(err.message, c.error.message, c.name .. ": message")
  end
  for k, v in pairs(c.error.fields or {}) do
    t.eq(err[k], v, c.name .. ": " .. k)
  end
end

local function drain_parts(next_fn)
  local items = {}
  while true do
    local item, err = next_fn()
    if item == nil then
      return items, err
    end
    items[#items + 1] = item
  end
end

t.describe("streams match Distilled's TS", function()
  for _, c in ipairs(golden.cases) do
    t.it(c.kind .. ": " .. c.name, function()
      local tr = stub.transport({ reply_of(c) })
      local host = testing.host({ transport = tr })
      local items, err
      if c.kind == "boxd" then
        local Boxd = require("boxd")
        local client = Boxd.new({
          token = "bxd_tok",
          base_url = "https://boxd.test",
          host = host,
          retry = "none",
        })
        local stream_method = client[c.op .. "_stream"]
        if stream_method then
          local s, serr = stream_method(client, c.input)
          if s == nil then
            items, err = {}, serr
          else
            items, err = drain_parts(function()
              return s:next()
            end)
          end
        else
          -- until the client grows `<op>_stream` (task 29), the protocol directly
          local state = client._state
          local ctx = {}
          for k, v in pairs(state.ctx) do
            ctx[k] = v
          end
          local parts, perr = state.protocol.stream(ctx, state.service.ops[c.op], c.input)
          if parts == nil then
            items, err = {}, perr
          else
            items, err = drain_parts(parts.next)
          end
        end
      else
        local Process = require("e2b.process")
        local Filesystem = require("e2b.filesystem")
        local opts = { sandbox_id = "sb-1", access_token = "envd-tok", host = host }
        local client, method
        if c.fn == "watchDir" then
          client, method = Filesystem.new(opts), "watch_dir_stream"
        elseif c.fn == "connectProcess" then
          client, method = Process.new(opts), "connect_process_stream"
        else
          client, method = Process.new(opts), "start_process_stream"
        end
        local s, serr = client[method](client, c.input)
        if s == nil then
          items, err = {}, serr
        else
          items, err = drain_parts(function()
            return s:next()
          end)
        end
      end
      check_request(c, tr.requests[1])
      check_outcome(c, items, err)
      t.truthy(tr.readers[1].closed, "the reader is closed")
    end)
  end
end)
