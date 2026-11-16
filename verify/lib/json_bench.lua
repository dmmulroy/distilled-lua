-- Times json.decode (and json.encode) of one file:
--   lua verify/lib/json_bench.lua <file>      rex do verify/lib/json_bench.lua file=<file>
-- os.clock is CPU time in lua/luajit and wall time in gopher-lua; both are fine for a
-- single-threaded decode.
local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
local root = (string.match(source, "^(.*)/verify/lib/[^/]*$")) or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local json = require("distilled.json")
local rex_api = rawget(_G, "rex")
local path = rex_api and rex_api.args.file or arg[1]
local f = assert(io.open(path, "rb"))
local text = f:read("*a")
f:close()

local runs = 3
local best_decode, best_encode = math.huge, math.huge
local value
for _ = 1, runs do
  local t0 = os.clock()
  local v, err = json.decode(text)
  local t1 = os.clock()
  if not v then
    error(tostring(err), 0)
  end
  value = v
  local out = json.encode(value)
  local t2 = os.clock()
  assert(out)
  if t1 - t0 < best_decode then
    best_decode = t1 - t0
  end
  if t2 - t1 < best_encode then
    best_encode = t2 - t1
  end
end
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local line = string.format(
  "%-8s %s: %d bytes, decode %.1f ms, encode %.1f ms (best of %d)",
  runtime,
  string.match(path, "[^/]*$"),
  #text,
  best_decode * 1000,
  best_encode * 1000,
  runs
)
print(line)
