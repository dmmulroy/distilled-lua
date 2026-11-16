-- dl conform, responses: what the generated Lua client makes of each canned response,
-- against Distilled's outcome (ref/<provider>/responses.jsonl).
--
-- Compared as JSON: a decoded value (a secret is { $redacted = <value> }, raw bytes are
-- { $bytes_b64 = ... }), or the error's tag, categories, retryable and throttling marks,
-- status, code, message, retry_after (seconds) and body.
local json = require("distilled.json")
local schema = require("distilled.schema")
local secret = require("distilled.secret")
local testing = require("distilled.testing")
local lib = require("verify.conform.lib")
local diff = require("verify.conform.diff")
local env = require("verify.conform.env")

local check = {}

check.EPOCH = 1700000000

--- view(v): JSON-able view of a decoded Lua value (bounded depth)
function check.view(v, depth)
  depth = depth or 0
  if depth > 60 then
    return "(too deep)"
  end
  if secret.is(v) then
    return { ["$redacted"] = check.view(secret.unwrap(v), depth + 1) }
  end
  if type(v) ~= "table" or v == json.null then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = check.view(x, depth + 1)
  end
  if json.is_array(v) then
    return json.array(out)
  end
  if not json.is_object(v) and #v > 0 then
    return json.array(out)
  end
  return json.object(out)
end

function check.error_view(err)
  local cats = {}
  for name, on in pairs(err.categories or {}) do
    if on then
      cats[#cats + 1] = name
    end
  end
  table.sort(cats)
  return {
    tag = err.tag,
    categories = json.array(cats),
    retryable = err.retryable == true,
    throttling = err.throttling == true,
    status = err.status,
    code = err.code,
    message = err.message,
    retry_after = err.retry_after,
    body = check.view(err.body),
  }
end

local function response_of(r)
  local body = r.body
  if r.body_b64 then
    body = lib.b64_decode(r.body_b64)
  end
  return { status = r.status or 200, headers = r.headers or {}, body = body or "" }
end

--- outcome(ctx, op_name, input, script, opts) -> { ok, value | error }, host
-- script(n, req) -> response | nil (a transport failure)
function check.outcome(ctx, op_name, input, script, opts)
  opts = opts or {}
  local host
  local transport = testing.transport({
    responses = setmetatable({}, {
      __index = function(_, n)
        return function(req)
          local r = script(n, req)
          if r == nil then
            return nil, require("distilled.errors").new("TransportError", { message = "reset" })
          end
          return response_of(r)
        end
      end,
    }),
  })
  host = testing.host({ epoch = check.EPOCH, now = 0, transport = transport, seed = 1 })
  host.random = function()
    return 0.5
  end
  local client = env.client(ctx, {
    transport = transport,
    sleep = host.sleep,
    now = host.now,
    epoch = host.epoch,
    random = host.random,
    validation = opts.validation or "lenient",
    retry = opts.retry or "none",
  })
  local method = client[op_name]
  local value, err = method(client, lib.to_lua(input))
  local op = ctx.service.ops[op_name]
  if err then
    return { ok = false, error = check.error_view(err) }, host
  end
  local out = op.output and schema.resolve(op.output, ctx.service.shapes)
  if out and out.t == "blob" and type(value) == "string" then
    return { ok = true, value = { ["$bytes_b64"] = lib.b64_encode(value) } }, host
  end
  local v = check.view(value)
  if v == nil then
    v = json.null
  end
  return { ok = true, value = v }, host
end

local function strip_id(rec)
  local out = {}
  for k, v in pairs(rec) do
    if k ~= "id" then
      out[k] = v
    end
  end
  return out
end

function check.run(ctx)
  local cases = lib.read_lines(ctx.cases_dir .. "/responses.jsonl")
  local refs = lib.read_lines(ctx.ref_dir .. "/responses.jsonl")
  local by_id = {}
  for _, r in ipairs(refs) do
    by_id[r.id] = r
  end
  local results = {}
  for i, case in ipairs(cases) do
    local want = by_id[case.id]
    local result = { id = case.id, line = i, file = "responses.jsonl", case = case }
    if not want then
      result.diffs = { { path = "ref", a = "(no reference: rerun without --replay)", b = "" } }
    elseif ctx.skip and ctx.skip(case, ctx) then
      result.skipped = ctx.skip(case, ctx)
    else
      local got = check.outcome(ctx, case.op, case.input, function()
        return case.response
      end, { validation = case.validation })
      result.got = got
      result.diffs = diff.values(strip_id(want), got, "", {})
    end
    results[#results + 1] = result
  end
  return results
end

return check
