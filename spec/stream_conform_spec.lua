-- Boat's streaming operations vs Distilled's TS for the same canned bytes (task 29):
-- spec/golden/stream/boat.json is written by verify/lib/stream_conform.mjs (Distilled's
-- executeSandboxCommand.stream / attachCommand.stream / attachCommand over a stub
-- HttpClient). Compared: the request (method, URL, JSON body, authorization), every item,
-- and the error the stream ends with (tag, status, message where Distilled has one).
-- Deliberate differences: Lua sends `accept: application/x-ndjson, application/json`
-- (Distilled sends no accept) and no b3/traceparent without tracing; Lua's parse error
-- has a message (Distilled's is empty); a non-2xx reply fails the `_stream` call itself,
-- not the first pull (Distilled's Stream fails when it is run).
local t = require("spec.harness")
package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local json = require("distilled.json")
local testing = require("distilled.testing")

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local GOLDEN = assert(json.decode(read(t.root .. "/spec/golden/stream/boat.json")))

-- json.null and arrays compare by their encoding
local function enc(v)
  return assert(json.encode(v))
end

t.describe("stream: Boat vs Distilled", function()
  for _, c in ipairs(GOLDEN) do
    t.it(c.name, function()
      local tr = testing.stream_transport({
        responses = {
          { status = c.reply.status, headers = c.reply.headers, chunks = c.reply.chunks },
        },
      })
      local client = require("boat_dev").new({
        api_key = "boat_key",
        base_url = "https://boat.test/api/v1",
        transport = tr,
        retry = "none",
      })
      local items, err, value = {}, nil, nil
      if c.mode == "stream" then
        local s, oerr = client[c.op .. "_stream"](client, c.input)
        if s == nil then
          err = oerr
        else
          for item, ierr in s:iter() do
            if item then
              items[#items + 1] = item
            else
              err = ierr
            end
          end
        end
      else
        local tr_plain = testing.transport({
          responses = {
            {
              status = c.reply.status,
              headers = c.reply.headers,
              body = table.concat(c.reply.chunks),
            },
          },
        })
        tr = tr_plain
        client = client:with({ transport = tr_plain })
        value, err = client[c.op](client, c.input)
      end
      -- the request
      local want, got = c.sent[1], tr.requests[1]
      t.eq(got.method, want.method)
      t.eq(got.url, want.url)
      t.eq(got.headers["authorization"], want.headers["authorization"])
      if want.body == json.null then
        t.eq(got.body, nil)
      else
        t.eq(enc(json.decode(got.body)), enc(json.decode(want.body)))
      end
      -- the outcome
      if c.mode == "call" then
        t.eq(enc(value), enc(c.value))
        return
      end
      t.eq(enc(json.array(items)), enc(json.array(c.items)))
      if c.error == nil then
        t.eq(err, nil)
      else
        t.truthy(err, "an error")
        t.eq(err.tag, c.error.tag)
        if c.error.message and c.error.message ~= "" then
          t.eq(err.message, c.error.message)
        end
        if c.error.fields.status then
          t.eq(err.status, c.error.fields.status)
        end
      end
    end)
  end
end)
