# Task 03: schemas and the wire algorithms (done)

## What was built

| File | What |
| --- | --- |
| `lua/distilled/schema.lua` | node constructors (`S.string` ... `S.struct`, `S.member`, `S.sensitive`, `S.scalar`), `resolve` (ref chains, `SdkError` on a missing name or a ref cycle), `plan` (members by binding, cached per node, Distilled's `planFor`), `memo` (per registry + node caches), value helpers, `pick_arm` (union arm selection) |
| `lua/distilled/url.lua` | `encode_component` (encodeURIComponent), `encode_form` (URLSearchParams), `encode_greedy_label`, `text` (JavaScript `String(v)`), ordered `query()`, `fill`, `placeholders` |
| `lua/distilled/request.lua` | `request.build`, port of `buildRequest` (labels, query, headers, body, payload, form-urlencoded, `{}` rule, content-type) |
| `lua/distilled/keys.lua` | `keys.encode` / `keys.decode` (`mapKeys`), `keys.verbatim` (`mapsVerbatim`), `keys.string_encode`; array/object marking |
| `lua/distilled/redact.lua` | `wrap` (`wrapSensitive`), `parsed` (`redactParsed`), `holds_sensitive`, `plain` (`redactPlain`) |
| `lua/distilled/validate.lua` | `check` (`response-validation-strict.ts`, both modes), `withhold` |
| `lua/distilled/regex.lua` | JavaScript regex subset as a Pike VM over UTF-16 code units (linear, no recursion, no backtracking) |
| `lua/distilled/errors.lua` | only the `regex_test` hook: compile once per source, cache, a source that does not compile never matches |
| `lua/distilled/testing/init.lua` | `testing.transport{ responses }`, `testing.host{ now, seed, env, responses }`, `testing.random(seed)` |
| `lua/distilled/testing/fixtures.lua` | Neon-shaped fake service: `get_project`, `list_projects` (cursor pagination), `create_project` (regex error matcher), `update_branch` (2 labels, header, renamed + string-encoded body), `create_api_key` (sensitive output), `get_bucket_object` (greedy label, raw output); canned bodies |
| specs | `schema url request keys redact validate regex testing` (208 tests), plus one replaced test in `errors_spec` |
| `verify/features/` | `request-building.md`, `key-mapping.md`, `redaction.md`, `validation.md` |

## Commands run (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 ...
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
...
== summary
  lua: ok 470 passed [Lua 5.5]
  luajit: ok 470 passed [luajit]
  rex: ok 469 passed, 1 pending [rex]
(exit 0)

$ for s in schema url request keys redact validate regex testing errors; do lua spec/run.lua ${s}_spec; done
schema ok 16 · url ok 12 · request ok 61 · keys ok 25 · redact ok 20 · validate ok 22
regex ok 36 · testing ok 16 · errors ok 40     (same counts under luajit; rex: regex 35 + 1 pending)

$ stylua --check lua/distilled/{schema,url,request,keys,redact,validate,regex,errors}.lua \
    lua/distilled/testing spec/{url,request,regex,errors,keys,redact,validate,schema,testing}_spec.lua
(clean)
```

The full run includes task 02's specs; all passed, nothing to report there.

The one pending test under Rex is the live Node differential for the regex engine (Rex
has no `io.popen`). Under lua and luajit it runs `node -e` on all 169 recorded
pattern/text pairs and checks that Node, the recording and the engine agree.

## Evidence for the requirements

- **Percent-encoding, all 256 bytes:** `url_spec` compares bytes 0-127 with strings
  recorded from Node's `encodeURIComponent` and `URLSearchParams`, checks 128-255 are
  escaped byte by byte (what JavaScript produces for the UTF-8 of each character), and
  compares UTF-8 strings (é, CJK, emoji) with Node.
- **Regex:** all 36 distinct patterns (38 uses) compile; 169 recorded pattern/text pairs
  match Node, at least one per patch pattern. That includes `[’']` (a multi-byte
  character in a class), `[\s\S]`, `.` against `\n`, `\u2028`, astral characters as two
  code units, `$` before a trailing `\n`, and Annex B literals (`x{`, `]`, `\e`). 22
  unsupported forms fail with a message that names the pattern: lookahead, lookbehind,
  `\1`, `\k`, `(?i)`, `(?i:`, `\p`, `\P`, `\u{}`, legacy octal, nothing to repeat,
  out-of-order ranges and quantifiers, unbalanced groups and classes, a trailing `\`.
  The 20,000-character `^(a+)+$` case is linear under gopher-lua too.
- **No recursion over data:** keys (600 levels), redact (500), validate (700) walk deep
  recursive values in all three runtimes.
- **Error paths:** InvalidInput for `.`/`..`, greedy segments, missing labels, CR/LF
  headers, non-table input, NaN and cyclic bodies; SdkError for multipart, missing
  refs, non-struct inputs; misuse raises. Errors never contain secret input values
  (canary check in `request_spec`).

## Distilled test cases ported

- `protocol-http.test.ts`: StringEncoded members (all 4), empty JSON bodies (2), URI label
  encoding ("keeps the existing escaping", the escape cases of "preserves only modeled
  pchar delimiters"), greedy labels (2), dot-segment labels (2), sensitive union
  responses (2), sensitive untyped members (2), UnionCases decoding (3, adapted: arm
  choice is shown by renaming, see below).
- `protocol-rest.test.ts`, request encoding: path/query/header/body, CommaDelimited,
  unwraps secrets, auth headers from the caller, mapMemberHeader, unknownKeyToWire,
  unmodeled keys verbatim. Raw request bodies: raw body under the Content-Type member,
  bodyMediaType fallback, JSON body under the Content-Type member or application/json,
  body fields under the Content-Type member with a set payload winning. Label refusal
  (`..`) at the request level.
- `sensitive.test.ts`: all 6 (holdsSensitive x3, redactPlain, redactParsed x3).
- `response-validation-strict.test.ts`: exact mode paths with open/empty structs,
  path and expected type (1-based index), open structs, recursive schemas.
  `response-validation.test.ts`: the checker's half of "additionalProperties passes
  extras", "missing required member" (both modes), "strict fails an unmodeled member at
  its path", "strict passes exact members", "open object and empty struct".

## Not ported, and why

- **Multipart** (`multipart binary parts`, `multipart file lists`): out of scope by the
  brief; `request.build` returns SdkError naming the operation.
- **`LabelEncoding({ preserve })`**: not in the member contract; labels always use full
  encodeURIComponent escaping.
- **`KeyDictionary` / `mapKeysByDictionary`, UnionCases member dictionaries** ("UnionCases
  member dictionaries" tests): no dictionary field in the node contract, so opaque content
  is never renamed.
- **UnionCases dropping inactive-case keys on decode:** the contract's union cannot tell a
  merged-case union from a Smithy union, so keys the chosen arm does not declare pass
  through instead of being dropped (the conservative choice; nothing is lost). If task 06
  needs Distilled's behaviour, a `merged = true` flag on the union would carry it.
- **Response header members, `withResponseHeaders`, decode-side tests** (204 bodies,
  transformResponse, parse errors, raw/binary outputs, typed error matching): those
  belong to the REST protocol (task 04). `schema.plan(output).by_bind.header` is there
  for it.
- **Random-schema comparison against Effect Schema** (`accepts exactly what Effect Schema
  accepted`) and real Effect schemas with refinements: not applicable (no Effect).
- **Blob/ArrayBuffer/Uint8Array distinctions:** Lua has only strings; a `blob` payload
  schema (or `op.body_media_type`) means raw bytes.

## Deliberate differences from `buildRequest` / `mapKeys`

- A missing label fails with InvalidInput (Distilled sends `/things/{id}`).
- A header value with CR or LF fails with InvalidInput (fetch would reject it later).
- Nested query objects, nested form objects and undeclared input keys use sorted key
  order (Lua tables have no insertion order); declared members keep declaration order.
- An undeclared key that collides with a member's renamed key loses to the member
  (Distilled: the later write wins, which is the undeclared key).
- An unmarked table at a map/struct node is an object even when its keys are 1..n.
- Validation paths use 1-based list indices.

## Open problems (also in STATUS.md)

- `secret.unwrap_deep` turns `json.null` into `{}`; `request.build` uses its own copy.
  Fix belongs in `secret.lua` (task 01).
- `spec/errors_spec.lua`: I replaced the placeholder test that asserted `matches` never
  matches, which the brief's regex hook makes false. No other edits outside my files.
- `verify/features/errors.md` (stale `matches` gotcha) and `verify/features/README.md`
  (new areas) need their owner's update; `docs/interfaces.md` additions are listed in
  STATUS.md.
