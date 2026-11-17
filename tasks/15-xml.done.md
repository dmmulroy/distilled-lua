# Task 15 (xml): done

## What was built

- `lua/distilled/xml.lua`: a port of `../distilled/packages/core/src/xml.ts`.
  - `xml.decode(text, options?)` (parseXmlSync/parseXml): DTD-free XML 1.0 into plain
    tables (text-only element = string; otherwise children by name, `@_attr`, `#text`;
    repeated siblings = list). Entities, numeric character references (range checks,
    leading zeros), CDATA, comments, PIs, the XML declaration grammar, BOM, line-end and
    attribute whitespace normalisation, XML 1.0 Unicode names (astral too), forbidden
    characters, duplicate attributes, every xml.ts failure with the same message and
    line:column. Limits `max_depth` (256) and `max_length` (64 MiB, bytes).
  - Iterative scanner (explicit element stack, no recursion over depth), text chunks
    joined once with `compat.concat`, failures raised internally and caught once with
    `compat.pcall` (so no plain `pcall`), returned as `ParseError` tables. Unexpected
    raises become `ParseError` "XML could not be parsed: ..." like xml.ts's parseXml.
  - `xml.escape`, `xml.wrap_tag`, `xml.is_list`, `xml.MAX_DEPTH`, `xml.MAX_LENGTH`.
- `spec/xml_spec.lua` (37 tests), in the manifest: the upstream fast-xml-parser corpus
  (77 docs, copied to `spec/fixtures/xml/upstream-validator.json`), every case of
  `core/test/xml.test.ts`, 65 malformed inputs with Distilled's exact messages, offsets,
  lines and columns (measured in Node), CRLF line counting, UTF-16 columns, 11 kinds of
  invalid UTF-8, 400 random/corrupted inputs that must never raise, limits and option
  misuse, 10,000-level nesting (walked iteratively), a 5.3 MB document, and five real AWS
  bodies (S3 ListObjectsV2, EC2 DescribeInstances, S3 NoSuchKey error, query
  ErrorResponse, EC2 Response/Errors) compared with xml.ts's output stored in
  `*.expected.json` (written by `verify/lib/xml_fixtures.mjs`).
- Differential check `verify/dl test --xml-fuzz`: `verify/lib/xml_gen.mjs` (Node, imports
  xml.ts) writes ~18,000 documents (corpus, xml.ts test cases, fixtures, xml.ts's test
  generator, a wider generator, each with a truncation and a corruption) as WTF-8 with
  Distilled's outcome; `verify/lib/xml_diff.lua` parses them under each runtime; outputs
  (tree as sorted-key JSON, or error message) must match byte for byte. Prints MB/s.
- `verify/dl xml-bench [file]`: throughput per runtime and of xml.ts in Node on the same
  5.3 MB S3 page (`verify/lib/xml_bench.lua`).
- `verify/features/xml.md`; `STATUS.md` section 15.

## Found in Distilled

xml.ts's ASCII-name fast path regex backtracks, so it rejects names that continue past
ASCII (`<Straße>1</Straße>` -> "Expected whitespace or tag terminator at 1:5"; Distilled's
own reference parser accepts it). distilled.xml reads the full name. The fuzz uses xml.ts
with that one pattern fixed, asserts the patched parser equals the reference parser on
every document, and counts the documents unpatched xml.ts gets wrong (3,509 of 18,163 in
the default run). Everything else matches unpatched xml.ts exactly.

## Commands run (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test xml
== summary
  lua: ok 37 passed [Lua 5.5]
  luajit: ok 37 passed [luajit]
  rex: ok 37 passed [rex]

$ verify/dl test
== summary
  lua: ok 1085 passed, 4 pending [Lua 5.5]
  luajit: ok 1085 passed, 4 pending [luajit]
  rex: ok 1078 passed, 7 pending [rex]
(the pending tests are other tasks' HTTP/Rex-gated specs; none is xml)

$ verify/dl test --xml-fuzz
node: 18163 documents (3037 parse, 15126 rejected), 2.64 MB; 3509 differ from unpatched xml.ts only by its ASCII-name bug
ok   xml-fuzz lua: 18163 documents, 2.64 MB parsed in 0.23 s (11.34 MB/s) (seed 20261116), all match Distilled's xml.ts
ok   xml-fuzz luajit: 18163 documents, 2.64 MB parsed in 0.43 s (6.12 MB/s) (seed 20261116), all match Distilled's xml.ts
ok   xml-fuzz rex: 18163 documents, 2.64 MB parsed in 1.09 s (2.42 MB/s) (seed 20261116), all match Distilled's xml.ts

$ DL_FUZZ_SEED=4242 DL_FUZZ_COUNT=10000 verify/dl test --xml-fuzz
node: 60163 documents (10016 parse, 50147 rejected), 8.34 MB; 11520 differ from unpatched xml.ts only by its ASCII-name bug
ok   xml-fuzz lua: 60163 documents, 8.34 MB parsed in 0.70 s (12.00 MB/s) (seed 4242), all match Distilled's xml.ts
ok   xml-fuzz luajit: 60163 documents, 8.34 MB parsed in 1.40 s (5.97 MB/s) (seed 4242), all match Distilled's xml.ts
ok   xml-fuzz rex: 60163 documents, 8.34 MB parsed in 3.41 s (2.45 MB/s) (seed 4242), all match Distilled's xml.ts

$ verify/dl xml-bench
Lua 5.5: 5.33 MB in 0.310 s (17.2 MB/s), root ListBucketResult
Lua 5.1 LuaJIT 2.1.1794386141: 5.33 MB in 0.177 s (30.1 MB/s), root ListBucketResult
Lua 5.1 (rex): 5.33 MB in 1.285 s (4.1 MB/s), root ListBucketResult
node v24.22.1 xml.ts: 5.33 MB in 0.046 s (115.5 MB/s)

$ verify/dl fmt --check      # exit 0
```

Seeds 1, 2, 3, 7 and 99 were also run during development (lua): all identical to Node.
A mutation check (accepting encoded surrogates) made `spec/xml_spec.lua` fail as expected.

## Deviations from xml.ts (documented in the module header and xml.md)

- Input is UTF-8 bytes: invalid UTF-8 is "Invalid XML character" (Distilled's protocols
  run the body through TextDecoder, which substitutes U+FFFD instead).
- `err.offset` and `max_length` are in bytes; line, column and message are Distilled's.
- Options are `max_depth` / `max_length`; messages say "Invalid max_depth".
- The ASCII-name bug above is not reproduced.

## Skipped / not verified

- No live AWS calls (none allowed); the AWS bodies are hand-written from AWS's documented
  examples, and their expected trees come from xml.ts, not from a real response.
- Byte offsets of errors are not compared with Node in the fuzz (Node's are UTF-16); the
  fuzz compares messages, which carry line:column. The spec checks byte offsets by hand.
- LuaJIT is slower than lua 5.5 on the fuzz corpus (many tiny documents, 83% rejected:
  the cost is the per-document coroutine of compat.pcall and error unwinding), faster
  on the large document. Not optimised further.

## Open problems

- `verify/features/README.md` does not list `xml.md` yet (orchestrator).
- `docs/interfaces.md` has no `distilled.xml` entry; the proposed API is in STATUS.md.
- S3's protocol helpers (`elementText`, `readXmlMap`, list unwrapping) are for the AWS
  protocol tasks.
