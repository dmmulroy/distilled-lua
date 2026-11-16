-- Load time and memory of a generated client, in the runtime this runs under.
--
--   lua verify/lib/gen_load_bench.lua <root> <clients dir> <provider>
--   rex do verify/lib/gen_load_bench.lua root=<root> dir=<clients dir> provider=<provider>
--
-- Measures, separately: the runtime modules the client needs (distilled.client and what
-- it requires), then require("<provider>.service") (the generated data), then
-- require("<provider>") (the class). Times are os.clock (CPU time in lua/luajit, wall
-- time in gopher-lua); memory is collectgarbage("count") after a full collection, which
-- gopher-lua does not report.
local rex_api = rawget(_G, "rex")
local root, dir, provider
if rex_api then
  local a = rawget(rex_api, "args") or {}
  root, dir, provider = a.root, a.dir, a.provider
else
  root, dir, provider = arg[1], arg[2], arg[3]
end
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. dir
  .. "/?.lua;"
  .. dir
  .. "/?/init.lua;"
  .. package.path

local function kb()
  collectgarbage("collect")
  collectgarbage("collect")
  local n = collectgarbage("count")
  return type(n) == "number" and n or nil
end

local function step(fn)
  local m0 = kb()
  local t0 = os.clock()
  fn()
  local ms = (os.clock() - t0) * 1000
  local m1 = kb()
  return ms, (m0 and m1) and (m1 - m0) or nil
end

local function fmt_kb(v)
  return v and string.format("%.0f KB", v) or "n/a"
end

local rt_ms, rt_kb = step(function()
  require("distilled.client")
  require("distilled.protocol.rest")
end)
local svc_ms, svc_kb = step(function()
  require(provider .. ".service")
end)
local cls_ms, cls_kb = step(function()
  require(provider)
end)
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local line = string.format(
  "%-8s runtime modules %.1f ms %s | %s.service %.1f ms %s | %s class %.1f ms %s",
  runtime,
  rt_ms,
  fmt_kb(rt_kb),
  provider,
  svc_ms,
  fmt_kb(svc_kb),
  provider,
  cls_ms,
  fmt_kb(cls_kb)
)
print(line)
return line
