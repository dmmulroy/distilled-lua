-- Parses the documents written by xml_gen.mjs with distilled.xml:
--   lua verify/lib/xml_diff.lua <inputs.bin> <out.txt>
--   rex do verify/lib/xml_diff.lua in=<inputs.bin> out=<out.txt>
-- Writes one line per document: the tree as JSON (keys sorted, as xml_gen.mjs writes
-- Distilled's), or "ERROR <message>". Prints the count and the parse throughput.
local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
local root = (string.match(source, "^(.*)/verify/lib/[^/]*$")) or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local compat = require("distilled.compat")
local json = require("distilled.json")
local xml = require("distilled.xml")

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

local docs = {}
local pos = 1
while pos <= #data do
  local nl = string.find(data, "\n", pos, true)
  local len = tonumber(string.sub(data, pos, nl - 1))
  docs[#docs + 1] = string.sub(data, nl + 1, nl + len)
  pos = nl + 1 + len
end

-- parse everything first, timed alone (os.clock: CPU time on lua/luajit, wall in Rex)
local results, errs = {}, {}
local bytes = 0
local started = os.clock()
for i = 1, #docs do
  results[i], errs[i] = xml.decode(docs[i])
  bytes = bytes + #docs[i]
end
local elapsed = os.clock() - started

local lines = {}
for i = 1, #docs do
  if errs[i] then
    lines[i] = "ERROR " .. errs[i].message
  else
    local text, eerr = json.encode(results[i])
    lines[i] = text or ("ERROR encode: " .. tostring(eerr))
  end
end

local out = assert(io.open(out_path, "wb"))
out:write(compat.concat(lines, "\n"), "\n")
out:close()
local summary = string.format(
  "%d documents, %.2f MB parsed in %.2f s (%.2f MB/s)",
  #docs,
  bytes / 1048576,
  elapsed,
  elapsed > 0 and bytes / 1048576 / elapsed or 0
)
print(summary)
return summary
