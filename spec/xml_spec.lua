-- distilled.xml, ported from Distilled's core/test/xml.test.ts, plus deep nesting, large
-- documents, invalid UTF-8, never-raises on random input, and real AWS bodies
-- (spec/fixtures/xml). `verify/dl test --xml-fuzz` compares with xml.ts in Node.
local t = require("spec.harness")
local json = require("distilled.json")
local xml = require("distilled.xml")

local FIXTURES = t.root .. "/spec/fixtures/xml/"

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function parse(text, options)
  local v, err = xml.decode(text, options)
  if err then
    t.fail("decode failed: " .. tostring(err.message))
  end
  return v
end

local function rejects(text, options)
  local v, err = xml.decode(text, options)
  return t.fails_with("ParseError", v, err)
end

t.describe("xml upstream fast-xml-parser validation corpus", function()
  t.it("accepts the valid documents and rejects the others, never raising", function()
    local corpus = assert(json.decode(read_file(FIXTURES .. "upstream-validator.json")))
    t.eq(#corpus, 77)
    for i, case in ipairs(corpus) do
      local valid = case.valid
      if case.parserValid ~= nil then
        valid = case.parserValid
      end
      local v, err = xml.decode(case.xml)
      if valid then
        t.eq(err, nil, i .. ": " .. case.name)
        t.eq(type(v), "table", i .. ": " .. case.name)
      else
        t.fails_with("ParseError", v, err)
      end
    end
  end)
end)

t.describe("xml object format", function()
  t.it("keeps primitives as strings and groups repeated children", function()
    t.same(parse("<R><x>001</x><x>false</x><x>1e3</x><empty/><empty></empty></R>"), {
      R = { x = { "001", "false", "1e3" }, empty = { "", "" } },
    })
  end)

  t.it("preserves namespace names, attributes, and text with attributes", function()
    t.same(parse('<ns:R xmlns:ns="urn:r"><ns:x ns:id="01">value</ns:x><empty a=""/></ns:R>'), {
      ["ns:R"] = {
        ["@_xmlns:ns"] = "urn:r",
        ["ns:x"] = { ["@_ns:id"] = "01", ["#text"] = "value" },
        empty = { ["@_a"] = "" },
      },
    })
  end)

  t.it("preserves string whitespace, including attribute and CDATA values", function()
    t.same(
      parse('<R><Key> key </Key><blank> \t </blank><x a=" b "> text </x><c><![CDATA[ c ]]></c></R>'),
      {
        R = {
          Key = " key ",
          blank = " \t ",
          x = { ["@_a"] = " b ", ["#text"] = " text " },
          c = " c ",
        },
      }
    )
  end)

  t.it("discards layout-only container text but preserves mixed content", function()
    t.same(parse("<R>\n  <x/>\n  <y/>\n</R>"), { R = { x = "", y = "" } })
    t.same(parse("<R>Hello <b>world</b> !</R>"), { R = { b = "world", ["#text"] = "Hello  !" } })
    t.same(parse("<R><![CDATA[ ]]><b/></R>"), { R = { b = "", ["#text"] = " " } })
  end)

  t.it("keeps layout text of an element with attributes and no children", function()
    t.same(parse('<R a="1">\n  </R>'), { R = { ["@_a"] = "1", ["#text"] = "\n  " } })
  end)

  t.it("decodes predefined and numeric entities exactly once", function()
    t.same(parse('<R a="&quot;&apos;&#9;">&amp;&lt;&gt;&#65;&#x1F600;&amp;lt;</R>'), {
      R = { ["@_a"] = "\"'\t", ["#text"] = "&<>A😀&lt;" },
    })
  end)

  t.it("decodes character references at the edges of the allowed ranges", function()
    t.same(parse("<R>&#x0010FFFF;&#0000065;&#xD7FF;&#xE000;&#xFFFD;&#x10000;&#32;</R>"), {
      R = "\244\143\191\191A\237\159\191\238\128\128\239\191\189\240\144\128\128 ",
    })
  end)

  t.it(
    "normalizes literal line endings and attribute whitespace, not character references",
    function()
      t.same(parse('<R a="x\r\ny\tz\r&#13;&#10;&#9;">a\r\nb\rc&#13;</R>'), {
        R = { ["@_a"] = "x y z \r\n\t", ["#text"] = "a\nb\nc\r" },
      })
    end
  )

  t.it("joins CDATA and text without decoding CDATA entities", function()
    t.same(parse("<R>a<![CDATA[<b>&amp;]]><![CDATA[c]]>d&amp;</R>"), { R = "a<b>&amp;cd&" })
    t.same(parse("<R><![CDATA[]]></R>"), { R = "" })
    t.same(parse("<R><![CDATA[a\r\nb\rc]]></R>"), { R = "a\nb\nc" })
  end)

  t.it("ignores declarations, comments and processing instructions", function()
    t.same(
      parse(
        '\239\187\191<?xml version="1.0" encoding="UTF-8" standalone="yes"?><!--before--><?before a?><R>a<!--ignored--><?in x?>b</R><?after?><!--after-->'
      ),
      { R = "ab" }
    )
    t.same(parse("<?xml version='1.0' standalone='no'?>\n<R/>"), { R = "" })
    t.same(parse('<?xml  version = "1.0"  ?><R/>'), { R = "" })
  end)

  t.it("supports XML Unicode names", function()
    t.same(parse('<根 é="oui"><𐀀>😀</𐀀><á/></根>'), {
      ["根"] = { ["@_é"] = "oui", ["𐀀"] = "😀", ["á"] = "" },
    })
  end)

  -- xml.ts's ASCII-name fast path cuts these names at the last ASCII character before
  -- the first non-ASCII one and fails; its reference parser and XML read the full name
  t.it("reads names that continue past ASCII (xml.ts rejects these)", function()
    t.same(parse("<Straße>1</Straße>"), { ["Straße"] = "1" })
    t.same(parse("<a><Größe x·y='1'/></a>"), { a = { ["Größe"] = { ["@_x·y"] = "1" } } })
  end)

  t.it("accepts empty HTTP bodies", function()
    for _, text in ipairs({ "", " \r\n\t", "\239\187\191" }) do
      t.same(parse(text), {})
    end
  end)

  t.it("stores metamethod and prototype names as plain keys of plain tables", function()
    local result = parse(
      "<__proto__><constructor>one</constructor><constructor>two</constructor><__proto__>safe</__proto__><toString/><__index>i</__index></__proto__>"
    )
    local root = result.__proto__
    t.same(
      root,
      { constructor = { "one", "two" }, __proto__ = "safe", toString = "", __index = "i" }
    )
    t.eq(getmetatable(result), nil)
    t.eq(getmetatable(root), nil)
    t.eq(getmetatable(root.constructor), nil)
  end)

  t.it("round trips escaped strings", function()
    for _, text in ipairs({ ' <tag a="x">&\'😀 ', "", "false", "001", "&#13;", "\t\n" }) do
      t.same(parse("<R>" .. xml.escape(text) .. "</R>"), { R = text })
    end
  end)

  t.it("handles large lists without recursion", function()
    local result = parse("<R>" .. string.rep('<item a="1">value</item>', 10000) .. "</R>")
    t.eq(#result.R.item, 10000)
    t.same(result.R.item[10000], { ["@_a"] = "1", ["#text"] = "value" })
  end)

  t.it("can parse the same text repeatedly", function()
    t.eq(parse("<R>ok</R>").R, "ok")
    t.eq(parse("<R>ok</R>").R, "ok")
  end)

  t.it("xml.is_list tells repeated children from one element", function()
    local r = parse("<R><x>1</x><x>2</x><y><z/></y><w>t</w></R>").R
    t.truthy(xml.is_list(r.x))
    t.falsy(xml.is_list(r.y))
    t.falsy(xml.is_list(r.w))
    t.falsy(xml.is_list(nil))
  end)

  t.it("a tree encodes as JSON with lists as arrays", function()
    t.eq(json.encode(parse('<R><x>1</x><x a="b"/></R>')), '{"R":{"x":["1",{"@_a":"b"}]}}')
  end)
end)

-- Every message and line:column is Distilled's (measured with xml.ts in Node); the
-- offset is in bytes (Distilled's is in UTF-16 units; they differ only past non-ASCII).
local INVALID = {
  { '<R a="1"a="2"/>', "Expected whitespace or tag terminator at 1:9", 8 },
  { '<R a="<"/>', "Unescaped '<' in attribute at 1:7", 6 },
  { '<R a="&bad;"/>', "Unknown or invalid entity reference at 1:7", 6 },
  { "<R a=1/>", "Expected quoted attribute at 1:7", 6 },
  { '<R a="1" a="2"/>', "Duplicate attribute at 1:11", 10 },
  { "<R/ >", "Expected whitespace or tag terminator at 1:3", 2 },
  { "< R/>", "Expected XML name at 1:2", 1 },
  { "<R></ R>", "Expected XML name at 1:6", 5 },
  { "<R></R x>", "Expected closing tag terminator at 1:8", 7 },
  { "<R>]]></R>", "Unexpected CDATA terminator at 1:4", 3 },
  { "<R>&</R>", "Unterminated entity reference at 1:4", 3 },
  { "<R>&amp</R>", "Unterminated entity reference at 1:4", 3 },
  { "<R>&nope;</R>", "Unknown or invalid entity reference at 1:4", 3 },
  { "<R>&#0;</R>", "Invalid character reference at 1:4", 3 },
  { "<R>&#xD800;</R>", "Invalid character reference at 1:4", 3 },
  { "<R>&#x110000;</R>", "Invalid character reference at 1:4", 3 },
  { "<R>&#xFFFE;</R>", "Invalid character reference at 1:4", 3 },
  { "<R>&#-1;</R>", "Unknown or invalid entity reference at 1:4", 3 },
  { "<R>&#X41;</R>", "Unknown or invalid entity reference at 1:4", 3 },
  { "<R>&#x;</R>", "Unknown or invalid entity reference at 1:4", 3 },
  { "<R>&#;</R>", "Unknown or invalid entity reference at 1:4", 3 },
  { "<R>&#99999999999999999999;</R>", "Invalid character reference at 1:4", 3 },
  { "<R>\0</R>", "Invalid XML character at 1:4", 3 },
  { "<R>\011</R>", "Invalid XML character at 1:4", 3 },
  { "<R>\237\160\128</R>", "Invalid XML character at 1:4", 3 }, -- U+D800 as WTF-8
  { "<R>\237\176\128</R>", "Invalid XML character at 1:4", 3 }, -- U+DC00
  { "<R>\239\191\190</R>", "Invalid XML character at 1:4", 3 }, -- U+FFFE
  { "<R>\239\191\191</R>", "Invalid XML character at 1:4", 3 }, -- U+FFFF
  { "<R><!--a--b--></R>", "Invalid comment at 1:4", 3 },
  { "<R><!--a---></R>", "Invalid comment at 1:4", 3 },
  { "<R><!--", "Unterminated comment at 1:4", 3 },
  { "<R><![CDATA[", "Unterminated CDATA at 1:4", 3 },
  { "<![CDATA[x]]><R/>", "CDATA outside root element at 1:1", 0 },
  { "<R/><![CDATA[x]]>", "CDATA outside root element at 1:5", 4 },
  { "<R><?pi", "Expected PI whitespace at 1:8", 7 },
  { "<R><?1bad?></R>", "Expected XML name at 1:6", 5 },
  { "<R><?pi!?></R>", "Expected PI whitespace at 1:8", 7 },
  { '<?XML version="1.0"?><R/>', "Invalid or misplaced XML declaration at 1:1", 0 },
  { "<?xml?><R/>", "Invalid or misplaced XML declaration at 1:1", 0 },
  { '<?xml version="1.1"?><R/>', "Invalid or misplaced XML declaration at 1:1", 0 },
  { '<?xml encoding="UTF-8"?><R/>', "Invalid or misplaced XML declaration at 1:1", 0 },
  { '<?xml version="1.0" junk="x"?><R/>', "Invalid or misplaced XML declaration at 1:1", 0 },
  { "<?xml version=\"1.0'?><R/>", "Invalid or misplaced XML declaration at 1:1", 0 },
  {
    '<?xml version="1.0" standalone="yes" encoding="UTF-8"?><R/>',
    "Invalid or misplaced XML declaration at 1:1",
    0,
  },
  { '<R><?xml version="1.0"?></R>', "Invalid or misplaced XML declaration at 1:4", 3 },
  { '<!--x--><?xml version="1.0"?><R/>', "Invalid or misplaced XML declaration at 1:9", 8 },
  { '<?xml version="1.0"?>', "Missing root element at 1:22", 21 },
  { "<!--only-->", "Missing root element at 1:12", 11 },
  { "<!DOCTYPE R><R/>", "DTDs and markup declarations are not supported at 1:1", 0 },
  {
    '<!DOCTYPE R SYSTEM "file:///etc/passwd"><R/>',
    "DTDs and markup declarations are not supported at 1:1",
    0,
  },
  {
    '<!DOCTYPE R [<!ENTITY a "&a;">]><R>&a;</R>',
    "DTDs and markup declarations are not supported at 1:1",
    0,
  },
  { "<R/><R/>", "Multiple root elements at 1:5", 4 },
  { "before<R/>", "Text outside root element at 1:1", 0 },
  { "<R/>after", "Text outside root element at 1:5", 4 },
  { "<R><x></R>", "Mismatched closing tag at 1:10", 9 },
  { "<R>", "Unclosed element at 1:4", 3 },
  { "<", "Expected XML name at 1:2", 1 },
  { '<R a="', "Unterminated attribute at 1:7", 6 },
  { "<R a", "Expected attribute equals sign at 1:5", 4 },
  { "<R a=", "Expected quoted attribute at 1:6", 5 },
  { "<R ", "Expected XML name at 1:4", 3 },
  { "</R>", "Mismatched closing tag at 1:4", 3 },
  { "<1bad/>", "Expected XML name at 1:2", 1 },
  { '<R\194\160a="x"/>', "Expected whitespace or tag terminator at 1:3", 2 },
  -- xml.ts fails one UTF-16 unit into the astral quote: column 12, our byte offset 13
  { "<a>😀<b x=😀/></a>", "Expected quoted attribute at 1:12", 13 },
}

t.describe("xml malformed and unsupported input", function()
  t.it("rejects each with Distilled's message, line and column, never raising", function()
    for _, case in ipairs(INVALID) do
      local text, message, offset = case[1], case[2], case[3]
      local ok, v, err = t.pcall(function()
        return xml.decode(text)
      end)
      t.truthy(ok, "raised on " .. string.format("%q", text))
      t.eq(v, nil, text)
      t.eq(type(err), "table", text)
      t.eq(err.tag, "ParseError", text)
      t.eq(err.message, message, text)
      t.eq(err.offset, offset, text .. " offset")
      t.eq(err.position, offset + 1, text .. " position")
      t.truthy(err.offset >= 0 and err.offset <= #text, text)
      local line, column = string.match(message, " at (%d+):(%d+)$")
      t.eq(err.line, tonumber(line), text)
      t.eq(err.column, tonumber(column), text)
    end
  end)

  t.it("reports original input offsets and CRLF-aware line numbers", function()
    local err = rejects("<R>\r\n&bad;</R>")
    t.eq(err.offset, 5)
    t.eq(err.line, 2)
    t.eq(err.column, 1)
    err = rejects("<R>\r\r\n\n&bad;</R>")
    t.eq(err.line, 4)
    t.eq(err.column, 1)
  end)

  t.it("counts columns in UTF-16 code units, as Distilled does", function()
    -- é is 2 bytes and 1 unit, 😀 is 4 bytes and 2 units
    local err = rejects("<R>é😀&bad;</R>")
    t.eq(err.offset, 9)
    t.eq(err.column, 7)
    t.eq(err.message, "Unknown or invalid entity reference at 1:7")
  end)

  t.it("rejects invalid UTF-8 as an invalid character, at its first byte", function()
    local cases = {
      "\128", -- stray continuation byte
      "\192\128", -- overlong NUL
      "\193\191", -- overlong
      "\224\128\128", -- overlong 3-byte
      "\240\128\128\128", -- overlong 4-byte
      "\244\144\128\128", -- past U+10FFFF
      "\245\128\128\128",
      "\255",
      "\226\130", -- truncated
      "\240\159\152", -- truncated 4-byte
      "\195(", -- lead byte without continuation
    }
    for _, bad in ipairs(cases) do
      local err = rejects("<R>ok" .. bad .. "</R>")
      t.eq(err.message, "Invalid XML character at 1:6", string.format("%q", bad))
      t.eq(err.offset, 5)
    end
    -- the first invalid character wins, whichever kind it is
    t.eq(rejects("<R>\255\1</R>").offset, 3)
    t.eq(rejects("<R>\1\255</R>").offset, 3)
    -- valid at the edges
    t.same(
      parse("<R>\244\143\191\191\239\191\189\194\128</R>"),
      { R = "\244\143\191\191\239\191\189\194\128" }
    )
  end)

  t.it("never raises on random bytes or corrupted documents", function()
    local seed = 12345
    local function rand(n)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return seed % n
    end
    local alphabet = {
      "<",
      ">",
      "/",
      "=",
      '"',
      "'",
      "&",
      ";",
      "#",
      "x",
      "a",
      "R",
      " ",
      "\n",
      "\r",
      "!",
      "?",
      "-",
      "[",
      "]",
      "é",
      "😀",
      "\255",
      "\0",
      "\237\160\128",
    }
    local base = '<?xml version="1.0"?><R a="1"><x>t&amp;</x><!--c--><![CDATA[d]]><?p i?></R>'
    for i = 1, 400 do
      local text
      if i % 2 == 0 then
        local parts = {}
        for j = 1, rand(40) do
          parts[j] = alphabet[rand(#alphabet) + 1]
        end
        text = table.concat(parts)
      else
        local at = rand(#base) + 1
        text = string.sub(base, 1, at - 1)
          .. alphabet[rand(#alphabet) + 1]
          .. string.sub(base, at + 1)
      end
      local ok, v, err = t.pcall(function()
        return xml.decode(text)
      end)
      t.truthy(ok, "raised on " .. string.format("%q", text) .. ": " .. tostring(v))
      if v == nil then
        t.eq(err.tag, "ParseError")
        t.truthy(err.offset >= 0 and err.offset <= #text)
        t.match(err.message, " at %d+:%d+$")
      else
        t.eq(type(v), "table")
      end
    end
  end)
end)

t.describe("xml limits and options", function()
  t.it("enforces depth and input length limits", function()
    parse("<a><b/></a>", { max_depth = 2 })
    t.match(rejects("<a><b/></a>", { max_depth = 1 }).message, "^XML depth limit exceeded at 1:4$")
    parse("<a/>", { max_length = 4 })
    t.eq(rejects("<a/>", { max_length = 3 }).message, "XML input length limit exceeded at 1:1")
    t.eq(rejects("<a/>", { max_depth = 0 / 0 }).message, "Invalid max_depth at 1:1")
    t.eq(rejects("<a/>", { max_depth = 0 }).message, "Invalid max_depth at 1:1")
    t.eq(rejects("<a/>", { max_depth = 1.5 }).message, "Invalid max_depth at 1:1")
    t.eq(rejects("<a/>", { max_depth = 1 / 0 }).message, "Invalid max_depth at 1:1")
    t.eq(rejects("<a/>", { max_length = -1 }).message, "Invalid max_length at 1:1")
    -- xml.ts reports these at the position after a BOM
    t.eq(rejects("\239\187\191<a/>", { max_depth = 0 }).message, "Invalid max_depth at 1:2")
    local nested = string.rep("<a>", 2000) .. string.rep("</a>", 2000)
    t.eq(rejects(nested).message, "XML depth limit exceeded at 1:769")
    parse(nested, { max_depth = 2000 })
  end)

  t.it("the default depth limit is 256 open elements", function()
    t.eq(xml.MAX_DEPTH, 256)
    parse(string.rep("<a>", 256) .. string.rep("</a>", 256))
    rejects(string.rep("<a>", 257) .. string.rep("</a>", 257))
  end)

  t.it("parses 10,000 levels of nesting with an explicit stack", function()
    local depth = 10000
    local text = string.rep("<a><n>x</n>", depth) .. "<leaf>end</leaf>" .. string.rep("</a>", depth)
    local v = parse(text, { max_depth = depth + 1 })
    -- walk it iteratively (t.same recurses, gopher-lua's stack is ~250 frames)
    local node, levels = v, 0
    while node.a do
      node = node.a
      levels = levels + 1
      t.eq(node.n, "x")
    end
    t.eq(levels, depth)
    t.eq(node.leaf, "end")
    t.match(rejects(text).message, "^XML depth limit exceeded")
    t.match(rejects(text, { max_depth = depth }).message, "^XML depth limit exceeded")
    -- unclosed at that depth: an error, not a stack overflow
    t.match(rejects(string.rep("<a>", depth), { max_depth = depth }).message, "^Unclosed element")
  end)

  t.it("parses a 5 MB document", function()
    local parts = { "<ListBucketResult>" }
    local entry = "<Contents><Key>photos/%d/Größe &amp; ü.jpg</Key><Size>%d</Size>"
      .. '<StorageClass tier="hot">STANDARD</StorageClass><ETag>&quot;%d&quot;</ETag></Contents>\n'
    local n = 40000
    for i = 1, n do
      parts[#parts + 1] = string.format(entry, i, i * 3, i)
    end
    parts[#parts + 1] = "</ListBucketResult>"
    local text = require("distilled.compat").concat(parts)
    t.truthy(#text > 5 * 1024 * 1024, "document size " .. #text)
    local v = parse(text)
    local contents = v.ListBucketResult.Contents
    t.eq(#contents, n)
    t.eq(contents[n].Key, "photos/" .. n .. "/Größe & ü.jpg")
    t.eq(contents[n].Size, tostring(n * 3))
    t.same(contents[1].StorageClass, { ["@_tier"] = "hot", ["#text"] = "STANDARD" })
    t.eq(contents[7].ETag, '"7"')
  end)

  t.it("raises only for misuse", function()
    t.raises(function()
      xml.decode(nil)
    end, "text must be a string")
    t.raises(function()
      xml.decode("<a/>", "x")
    end, "options must be a table")
    t.raises(function()
      xml.decode("<a/>", { maxDepth = 2 })
    end, "unknown option maxDepth")
    t.raises(function()
      xml.decode("<a/>", { max_depth = "2" })
    end, "max_depth must be a number")
  end)
end)

t.describe("xml real AWS bodies (spec/fixtures/xml)", function()
  local names = {
    "s3-list-objects-v2",
    "ec2-describe-instances",
    "s3-error-no-such-key",
    "aws-query-error",
    "ec2-error",
  }

  t.it("each parses to what Distilled's xml.ts produces (expected.json)", function()
    for _, name in ipairs(names) do
      local v = parse(read_file(FIXTURES .. name .. ".xml"))
      local expected = string.gsub(read_file(FIXTURES .. name .. ".expected.json"), "\n$", "")
      t.eq(json.encode(v), expected, name)
    end
  end)

  t.it("S3 ListObjectsV2: lists, entities, namespaces, non-ASCII keys", function()
    local r = parse(read_file(FIXTURES .. "s3-list-objects-v2.xml")).ListBucketResult
    t.eq(r["@_xmlns"], "http://s3.amazonaws.com/doc/2006-03-01/")
    t.eq(r.IsTruncated, "true")
    t.eq(r.KeyCount, "3")
    t.eq(r.NextContinuationToken, "1w41l63U0xa8q7smH50vCxyTQqdxo69O3EmK28Bi5PcROI4wI/EyIJg==")
    t.truthy(xml.is_list(r.Contents))
    t.eq(#r.Contents, 3)
    t.eq(r.Contents[1].ETag, '"fba9dede5f27731c9771645a39863328"')
    t.eq(r.Contents[1].Owner.DisplayName, "mtd@amazon.com")
    t.eq(r.Contents[2].Size, "0")
    t.eq(r.Contents[2].RestoreStatus.IsRestoreInProgress, "false")
    t.eq(r.Contents[3].Key, "photos/2006/März/über & ünder.jpg")
    t.eq(r.CommonPrefixes[2].Prefix, "photos/2006/May/")
  end)

  t.it("EC2 DescribeInstances: item lists, empty elements, one-item sets", function()
    local r = parse(read_file(FIXTURES .. "ec2-describe-instances.xml")).DescribeInstancesResponse
    t.eq(r.requestId, "8f7724cf-496f-496e-8fe3-example")
    local reservation = r.reservationSet.item -- one item: not a list
    t.falsy(xml.is_list(reservation))
    t.eq(reservation.groupSet, "")
    local instance = reservation.instancesSet.item
    t.eq(instance.instanceId, "i-1234567890abcdef0")
    t.eq(instance.instanceState.code, "16")
    t.eq(instance.reason, "")
    t.eq(instance.placement.groupName, "")
    t.eq(#instance.tagSet.item, 2)
    t.eq(instance.tagSet.item[2].value, 'a <b> & "c" — ünïcödé')
    t.eq(
      instance.networkInterfaceSet.item.privateIpAddressesSet.item.association.ipOwnerId,
      "amazon"
    )
  end)

  t.it("error bodies: S3 Error, query ErrorResponse, EC2 Response/Errors", function()
    local s3 = parse(read_file(FIXTURES .. "s3-error-no-such-key.xml")).Error
    t.eq(s3.Code, "NoSuchKey")
    t.eq(s3.Key, "photos/2006/missing.jpg")
    local query = parse(read_file(FIXTURES .. "aws-query-error.xml")).ErrorResponse
    t.eq(query.Error.Code, "InvalidClientTokenId")
    t.eq(query.Error.Type, "Sender")
    local ec2 = parse(read_file(FIXTURES .. "ec2-error.xml")).Response
    t.eq(ec2.Errors.Error.Code, "InvalidInstanceID.NotFound")
    t.eq(ec2.RequestID, "ea966190-f9aa-478e-9ede-example")
  end)
end)

t.describe("xml.escape and xml.wrap_tag", function()
  t.it("escapes the five special characters", function()
    t.eq(xml.escape([[a&b<c>d"e'f]]), "a&amp;b&lt;c&gt;d&quot;e&apos;f")
    t.eq(xml.escape(""), "")
    t.eq(xml.escape("😀 plain"), "😀 plain")
    t.eq(xml.escape("&amp;"), "&amp;amp;")
  end)

  t.it("wraps content in a tag with an optional escaped xmlns", function()
    t.eq(xml.wrap_tag("Tag", "content"), "<Tag>content</Tag>")
    t.eq(xml.wrap_tag("Tag", "", ""), "<Tag></Tag>")
    t.eq(
      xml.wrap_tag("CreateBucketConfiguration", "<x/>", 'http://s3/"doc"'),
      '<CreateBucketConfiguration xmlns="http://s3/&quot;doc&quot;"><x/></CreateBucketConfiguration>'
    )
  end)

  t.it("raises on non-string arguments", function()
    t.raises(function()
      xml.escape(1)
    end, "expected a string")
    t.raises(function()
      xml.wrap_tag("a", nil)
    end, "must be strings")
    t.raises(function()
      xml.wrap_tag("a", "b", 1)
    end, "xmlns must be a string")
  end)
end)
