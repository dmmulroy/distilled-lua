# XML codec (`distilled.xml`)

A port of Distilled's `core/src/xml.ts` (`parseXmlSync`, `escapeXml`, `wrapTag`), for the
AWS restXml / query / ec2 protocols, S3 and the REST providers that answer in XML.

## Sub-features

- `xml.decode(text, options?)`: DTD-free XML 1.0 into plain tables, the fast-xml-parser
  shape Distilled's protocols read:
  - an element with only text is a string (`""` when empty); with children or attributes
    it is a table: children by name, attributes as `"@_<name>"`, text as `"#text"`;
  - repeated children become a list in document order (`xml.is_list(v)`); one child is
    not wrapped (`<item>` once is a table, twice is a list of tables);
  - `"#text"` is kept for text plus attributes, for mixed content, and for CDATA;
    layout-only whitespace between children is dropped;
  - values stay strings; names are verbatim (no namespace resolution: `ns:x`,
    `@_xmlns:ns` are keys); XML 1.0 Unicode names including astral ones;
  - the five predefined entities and decimal/hex character references are decoded once;
    CDATA is joined undecoded; comments, PIs and the declaration are ignored; a UTF-8
    BOM is skipped; literal `\r\n`/`\r` become `\n` (in attributes, tab/CR/LF become a
    space), character references are not normalised;
  - an empty or whitespace-only body is `{}`.
- Refused with a `ParseError` (never raised): DTDs and `<!` declarations, unknown
  entities, out-of-range character references, forbidden characters (C0 controls,
  U+FFFE/U+FFFF, invalid UTF-8 including encoded surrogates), bad or misplaced
  declarations, `--` in comments, `]]>` in text, mismatched/unclosed tags, duplicate
  attributes, `<` in attribute values, several roots, text outside the root.
- Limits: `max_depth` (open elements, default `xml.MAX_DEPTH` = 256) and `max_length`
  (bytes, default `xml.MAX_LENGTH` = 64 MiB). The scanner keeps an explicit stack, so a
  10,000-deep document parses when `max_depth` allows it, on gopher-lua too.
- `xml.escape(s)` (`& < > " '`) and `xml.wrap_tag(tag, content, xmlns?)` for building
  request bodies.

## How a user reaches it

```lua
local xml = require("distilled.xml")
local tree, err = xml.decode(body)      -- err.tag == "ParseError"
-- err.message "Mismatched closing tag at 1:10", err.offset (0-based byte),
-- err.position (1-based byte), err.line, err.column (UTF-16 units, as Distilled)
local contents = tree.ListBucketResult.Contents
if not xml.is_list(contents) then contents = { contents } end
xml.wrap_tag("Tagging", "<TagSet>" .. xml.escape(v) .. "</TagSet>", "http://s3.amazonaws.com/doc/2006-03-01/")
```

## Driving it with `dl`

- `verify/dl test xml` runs `spec/xml_spec.lua` under lua, luajit and rex: the upstream
  fast-xml-parser corpus (77 documents), every case of Distilled's `xml.test.ts`, the
  63 malformed inputs with Distilled's exact messages, invalid UTF-8, 400 random
  corruptions (never raises), 10,000-level nesting, a 5 MB document, and five real AWS
  bodies (`spec/fixtures/xml/*.xml`) compared with what xml.ts produces
  (`*.expected.json`, written by `verify/lib/xml_fixtures.mjs`; rerun it after changing
  a fixture).
- `verify/dl test --xml-fuzz` is the differential check: `verify/lib/xml_gen.mjs`
  writes ~18,000 documents (the corpus, the xml.ts test cases, the fixtures, xml.ts's
  own test generator, a wider generator with Unicode names, astral and forbidden
  characters, character references at the range edges, line endings and declarations,
  each with a truncation and a corruption) and Distilled's outcome for each, tree or
  error message; `verify/lib/xml_diff.lua` parses them under each runtime and the
  outputs must match byte for byte. It prints the parse throughput per runtime.
  `DL_FUZZ_SEED`, `DL_FUZZ_COUNT` (documents per generator, default 3000) vary the run.
- `verify/dl xml-bench [file]` times `xml.decode` per runtime on a 5.3 MB S3
  ListObjectsV2 page (or the file given) and Distilled's xml.ts in Node on the same bytes.
  Measured: lua 5.5 ~17 MB/s, luajit ~28 MB/s, Rex ~4 MB/s, Node ~110 MB/s.

## Gotchas

- **Distilled bug, not copied:** xml.ts's ASCII-name fast path
  (`/[A-Za-z_:][\w:.-]*(?![^\0-\x7f])/y`) backtracks when a name continues past ASCII,
  so it rejects `<Straße>` ("Expected whitespace or tag terminator at 1:5"). Its own
  reference parser and XML read the whole name, and so does distilled.xml. The fuzz
  check therefore compares with xml.ts with that one pattern fixed, verifies every
  document against Distilled's reference parser too, and reports how many documents
  unpatched xml.ts gets wrong.
- Input must be UTF-8. Distilled decodes a body with `TextDecoder` first (invalid bytes
  become U+FFFD); here invalid UTF-8 is a `ParseError` ("Invalid XML character").
- `err.offset` is in bytes, Distilled's in UTF-16 units; line and column (and so the
  message) are identical. Where xml.ts fails one code unit into an astral character
  (`<b x=😀`), the offset is one byte into the character.
- Option names are snake_case (`max_depth`); an invalid value (0, 1.5, NaN, inf) is a
  `ParseError` "Invalid max_depth", as in xml.ts; a non-number or unknown option raises.
- A list is only made from repeated siblings: code that reads a list member must accept
  one element too (`xml.is_list`). Element tables only have string keys, so `v[1]` is
  only set on lists.
- Interleaved siblings lose their relative order (`<a/><b/><a/>` is `{ a = {..,..},
  b = .. }`), as in Distilled.
- gopher-lua quirks this works around: `table.concat` overflow (compat.concat), the
  ~250-frame stack (no recursion), `tonumber` on long digit strings (character
  references longer than 8 significant digits are rejected before conversion), plain
  `pcall` (the scanner's failures are caught once with compat.pcall).
