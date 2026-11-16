-- Round-trips the documents written by json_gen.mjs through distilled.json:
--   lua verify/lib/json_diff.lua <inputs.bin> <out.txt>
--   rex do verify/lib/json_diff.lua in=<inputs.bin> out=<out.txt>
-- Writes encode(decode(doc)) per line, or "ERROR <message>".
local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
local root = (string.match(source, "^(.*)/verify/lib/[^/]*$")) or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local json = require("distilled.json")

local rex_api = rawget(_G, "rex")
local in_path, out_path
if rex_api then
  in_path, out_path = rex_api.args["in"], rex_api.args.out
else
  in_path, out_path = arg[1], arg[2]
end

local f = assert(io.open(in_path, "rb"))
local data = f:read("*a")
f:close()

local lines = {}
local start = 1
while start <= #data + 1 do
  local stop = string.find(data, "\30", start, true)
  local doc = string.sub(data, start, (stop or #data + 1) - 1)
  local value, err = json.decode(doc)
  if err then
    lines[#lines + 1] = "ERROR " .. tostring(err)
  else
    local text, eerr = json.encode(value)
    lines[#lines + 1] = text or ("ERROR " .. tostring(eerr))
  end
  if not stop then
    break
  end
  start = stop + 1
end

local out = assert(io.open(out_path, "wb"))
out:write(table.concat(lines, "\n"), "\n")
out:close()
return #lines
