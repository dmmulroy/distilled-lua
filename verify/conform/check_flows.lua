-- dl conform, flows: scripted response sequences through a whole call, a pagination
-- traversal or a retry loop, against Distilled (ref/<provider>/flows.jsonl). Compared:
-- the requests sent (method, URL, time on the fake clock in ms) and the result (value,
-- items or pages, or the error plus what a traversal produced before it).
local json = require("distilled.json")
local lib = require("verify.conform.lib")
local diff = require("verify.conform.diff")
local responses = require("verify.conform.check_responses")

local check = {}

local function run_case(ctx, case)
  local function script(n)
    if n < #case.script then
      return case.script[n + 1]
    end
    return case.forever or "transport"
  end
  local client, _, sent = responses.session(ctx, script, { retry = case.retry })
  local input = lib.to_lua(case.input)
  local result
  if case.kind == "call" then
    local value, err = client[case.op](client, input)
    if err then
      result = { ok = false, error = responses.error_view(err) }
    else
      result = { ok = true, value = responses.value_view(ctx, case.op, value) }
    end
  else
    local it = client[case.op .. "_" .. case.kind](client, input)
    local got = json.array({})
    for x in it do
      got[#got + 1] = responses.view(x)
    end
    if it.err then
      result = { ok = false, error = responses.error_view(it.err), partial = got }
    else
      result = { ok = true, value = got }
    end
  end
  local requests = json.array({})
  for i, s in ipairs(sent) do
    requests[i] = s
  end
  return { requests = requests, result = result }, script(#sent - 1)
end

function check.run(ctx)
  local cases = lib.read_lines(ctx.cases_dir .. "/flows.jsonl")
  local refs = lib.read_lines(ctx.ref_dir .. "/flows.jsonl")
  local by_id = {}
  for _, r in ipairs(refs) do
    by_id[r.id] = r
  end
  local results = {}
  for i, case in ipairs(cases) do
    local want = by_id[case.id]
    local result = { id = case.id, line = i, file = "flows.jsonl", case = case }
    if not want then
      result.diffs = { { path = "ref", a = "(no reference: rerun without --replay)", b = "" } }
    elseif ctx.skip and ctx.skip(case, ctx) then
      result.skipped = ctx.skip(case, ctx)
    else
      local got, last = run_case(ctx, case)
      result.got = got.result
      result.want = want.result
      result.last_response = last
      result.diffs = diff.values(responses.strip_id(want), got, "", {})
    end
    results[#results + 1] = result
  end
  return results
end

return check
