-- Times distilled.xml on one large document:
--   lua verify/lib/xml_bench.lua [file] [write=<path>]
--   rex do verify/lib/xml_bench.lua [file=<path>] [write=<path>]
-- Without a file it builds big_document() (an S3 ListObjectsV2 page of about
-- 5 MB, with entities, attributes and non-ASCII keys); write=<path> saves it, so Node
-- can time Distilled's parser on the same bytes. Prints MB/s for the best of 3 runs
-- (os.clock: CPU time on lua/luajit, wall time in Rex).
local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
local root = (string.match(source, "^(.*)/verify/lib/[^/]*$")) or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local compat = require("distilled.compat")
local xml = require("distilled.xml")

-- ~5.3 MB: `entries` <Contents> elements (default 12,000).
local function big_document(entries)
  entries = entries or 12000
  local parts = {
    '<?xml version="1.0" encoding="UTF-8"?>\n',
    '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\n',
    "  <Name>bench-bucket</Name><Prefix></Prefix><KeyCount>",
    tostring(entries),
    "</KeyCount><MaxKeys>",
    tostring(entries),
    "</MaxKeys><IsTruncated>false</IsTruncated>\n",
  }
  for i = 1, entries do
    parts[#parts + 1] = string.format(
      "  <Contents>\n    <Key>photos/%d/Größe &amp; ünïcödé — %05d.jpg</Key>\n"
        .. "    <LastModified>2009-10-12T17:50:30.000Z</LastModified>\n"
        .. "    <ETag>&quot;%032x&quot;</ETag>\n"
        .. "    <ChecksumAlgorithm>CRC32</ChecksumAlgorithm>\n"
        .. "    <Size>%d</Size>\n"
        .. '    <StorageClass tier="%s">STANDARD</StorageClass>\n'
        .. "    <Owner><ID>75aa57f09aa0c8caeab4f8c24e99d10f8e7faeebf76c078efc7c6caea54ba06a</ID>"
        .. "<DisplayName>owner-%d</DisplayName></Owner>\n  </Contents>\n",
      i % 97,
      i,
      i * 7919,
      i * 31,
      i % 2 == 0 and "hot" or "cold",
      i % 13
    )
  end
  parts[#parts + 1] = "</ListBucketResult>\n"
  return compat.concat(parts)
end

local rex_api = rawget(_G, "rex")
local args = {}
if rex_api then
  args.file, args.write = rex_api.args.file, rex_api.args.write
else
  for _, a in ipairs(arg or {}) do
    local k, v = string.match(a, "^(%w+)=(.*)$")
    if k then
      args[k] = v
    else
      args.file = a
    end
  end
end
local text
if args.file then
  local f = assert(io.open(args.file, "rb"))
  text = f:read("*a")
  f:close()
else
  text = big_document()
end
if args.write then
  local f = assert(io.open(args.write, "wb"))
  f:write(text)
  f:close()
end
local best, tree, err = 1 / 0, nil, nil
for _ = 1, 3 do
  local t0 = os.clock()
  tree, err = xml.decode(text)
  local dt = os.clock() - t0
  if dt < best then
    best = dt
  end
end
if err then
  error("xml_bench: the document does not parse: " .. err.message)
end
local root_name = next(tree)
local summary = string.format(
  "%s: %.2f MB in %.3f s (%.1f MB/s), root %s",
  _VERSION .. (rawget(_G, "jit") and (" " .. jit.version) or "") .. (rex_api and " (rex)" or ""),
  #text / 1048576,
  best,
  best > 0 and #text / 1048576 / best or 0,
  tostring(root_name)
)
print(summary)
return summary
