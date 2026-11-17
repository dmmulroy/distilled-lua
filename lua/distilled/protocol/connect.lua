-- Connect unary calls over JSON (connectrpc.com), as Distilled's e2b and namespacelabs
-- SDKs make them: plain REST through distilled.protocol.rest. Each RPC is
-- `POST /<package>.<Service>/<Method>` with a proto3 JSON body, and a failure is a
-- `{ code, message, details? }` body (string codes such as "not_found") under an HTTP
-- status the server maps the code to, which the REST decoder classifies.
--
--   local protocol = connect.new{
--     prepare = rpc.prepare(settings),   -- fn(creds, host) -> settings | nil, err
--     ...every rest.new option (base_url, headers, unknown_tag, parse_tag, ...)
--   }
--
-- What Connect adds over rest.new: `empty_json_body` defaults to true (a unary call
-- posts `{}` for an empty message: e2b's envd answers a bodyless one with 415), and
-- `prepare` derives settings (distilled.protocol.rpc) before the request is built.
-- Distilled's server-streaming Connect calls (e2b's process.Start, process.Connect,
-- filesystem.WatchDir: hand-written in packages/e2b/src/connect.ts, not generated
-- operations) are not ported.
local compat = require("distilled.compat")
local errors = require("distilled.errors")
local rest = require("distilled.protocol.rest")

local connect = {}

--- connect.with_prepare(protocol, prepare) -> protocol whose credentials go through
-- prepare(creds, host) first (any protocol with call / encode / decode)
function connect.with_prepare(protocol, prepare)
  if prepare == nil then
    return protocol
  end
  local function wrap(ctx)
    ctx = ctx or {}
    local inner = ctx.credentials
    local copy = {}
    for k, v in pairs(ctx) do
      copy[k] = v
    end
    copy.credentials = function()
      local creds = {}
      if inner then
        local c, err = inner()
        if c == nil then
          return nil, err
        end
        creds = c
      end
      local r = compat.pack(compat.pcall(prepare, creds, ctx.host or {}))
      if not r[1] then
        if errors.is(r[2]) then
          return nil, r[2]
        end
        return nil,
          errors.new(
            "SdkError",
            { message = "the protocol's prepare raised: " .. tostring(r[2]), cause = r[2] }
          )
      end
      return r[2], r[3]
    end
    return copy
  end
  local out = {}
  for k, v in pairs(protocol) do
    out[k] = v
  end
  function out.call(ctx, op, input)
    return protocol.call(wrap(ctx), op, input)
  end
  function out.encode(ctx, op, input, creds)
    if creds ~= nil then
      return protocol.encode(ctx, op, input, creds)
    end
    return protocol.encode(wrap(ctx), op, input)
  end
  function out.decode(ctx, op, res)
    return protocol.decode(ctx, op, res)
  end
  return out
end

--- connect.new(opts) -> protocol
function connect.new(opts)
  if type(opts) ~= "table" then
    compat.raise("connect.new: expected an options table", 2)
  end
  local rest_opts = {}
  for k, v in pairs(opts) do
    if k ~= "prepare" then
      rest_opts[k] = v
    end
  end
  if rest_opts.empty_json_body == nil then
    rest_opts.empty_json_body = true
  end
  return connect.with_prepare(rest.new(rest_opts), opts.prepare)
end

return connect
