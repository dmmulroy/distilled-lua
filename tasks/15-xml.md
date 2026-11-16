# Task 15: XML codec

Read `tasks/10-parity-overview.md` first. AWS restXml / query protocols, S3 and a few REST
providers speak XML. Distilled has `../distilled/packages/core/src/xml.ts` (and its tests in
`../distilled/packages/core/test/`).

## Files you own

```text
lua/distilled/xml.lua (new)       parse + serialize
spec/xml_spec.lua (new) and manifest
verify/features/xml.md (new)
STATUS.md (section "15 xml")
```

## Requirements

1. Port `xml.ts`: whatever it parses into (element tree / plain object with attributes,
   text, namespaces, entities, CDATA, numeric character references) and serializes
   from, with the same edge cases. Pure Lua 5.1, no recursion over document depth
   (gopher-lua stack ~250 frames: explicit stack), `compat.concat` for joins, nothing
   that breaks on gopher-lua (see AGENTS.md).
2. Port its tests; add tests for deep nesting (10,000 levels), large documents (5 MB),
   malformed input (errors are `ParseError` tables, never raises), and a few real AWS
   responses (S3 ListObjectsV2, an EC2 DescribeInstances, an error body) under
   `spec/fixtures/xml/`.
3. Differential check against Node (`xml.ts` through `node --conditions=bun
   --experimental-transform-types`) on generated documents, as task 01 did for JSON
   (`verify/lib/json_diff.lua`), wired as a `verify/dl` subcommand or a `dl test` flag.
   Report throughput per runtime.
