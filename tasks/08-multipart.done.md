# Task 08: multipart request bodies — done

## What was built

- `lua/distilled/multipart.lua`: the file value (`multipart.file{ data, filename?,
  content_type? }`, recognized by `multipart.is_file`, kept by `secret.unwrap_deep`), and
  the RFC 7578 encoder (`multipart.encode(parts, { random })`). Escaping and line-break
  rules copy undici's FormData serializer, checked against Node 24's output. Boundary
  `----distilled-lua-` + 24 alphanumerics from `random`, drawn again (up to 16 times) while
  it occurs in any part, then `SdkError`. Built with `compat.concat` (linear; a 2 MB part
  plus 3,000 parts is a spec).
- `lua/distilled/request.lua`: the multipart branch replaces the `SdkError` refusal.
  Distilled's rules: parts under wire names in declaration order (undeclared keys after,
  sorted); files keep their filename (else the wire name) and content type (else
  `application/octet-stream`); a string at a blob node is a file part named after the
  member (Distilled's Uint8Array); a non-empty list of binaries is one part per element;
  other tables are JSON parts, scalars `String(v)`; `json.null`/absent omitted; a payload
  record is one part per entry in **sorted** order (Lua has no insertion order). Secrets
  are unwrapped on the same copy as other bodies. New optional args `random` and `host`.
- Generator: no `allow_unsupported` needed for multipart (`gen/init.lua`);
  `provider.UNSUPPORTED` is empty, the mechanism stays, and `"multipart"` there is now a
  stale-spec error (`provider.CLOSED_GAPS`). `gen/types.lua` declares `distilled.File`
  and types Blob members (and lists of Blob) of multipart inputs `distilled.File|string`.
  `providers/neon.lua` no longer lists the gap; `clients/neon/` regenerated (only
  `types.lua` changed).
- `verify/lib/gen_check.lua`: multipart operations must build like the others, with a
  `multipart/form-data; boundary=` content type and a closed body.
- Specs: `spec/multipart_spec.lua` (32 cases: encoder, escaping, boundary regeneration,
  failure paths, the ported `protocol-http.test.ts` "multipart binary parts" and
  "multipart file lists" cases, payload records, secrets, and a differential against
  Node's `Request.formData()`), the multipart cases in `spec/request_spec.lua`,
  `spec/gen_ops_spec.lua`, `spec/gen_provider_spec.lua`, and `spec/neon_client_spec.lua`
  (a whole-body check of a real Neon client call).
- `verify/features/request-building.md`: "Multipart bodies" section.

## The independent parser

`spec/multipart_spec.lua` feeds request.build's body to Node's `Request.formData()`
(undici) and compares names, filenames (with `"` and CRLF in them), content types and the
hex of every part: all 256 byte values, a part that contains the first boundary candidate
and `--\r\n` sequences, and a 16 KB part. It runs in **all three runtimes**: through
`io.popen` (body in a temp file) under lua and luajit, and through `rex.exec` (body on
stdin) under gopher-lua. It is `t.pending` when node cannot be run.

## Commands and output (final tree)

```text
$ verify/dl doctor
...
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
== summary
  lua: ok 1038 passed, 4 pending [Lua 5.5]
  luajit: ok 1038 passed, 4 pending [luajit]
  rex: ok 1032 passed, 6 pending [rex]

$ verify/dl gen-diff neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 2.1 ms; client loads
ok gen-check luajit: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 1.9 ms; client loads
ok gen-check rex: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 23.1 ms; client loads
gen-diff neon: ok

$ verify/dl test multipart
  lua: ok 32 passed [Lua 5.5]
  luajit: ok 32 passed [luajit]
  rex: ok 32 passed [rex]

$ verify/dl test formData        # the Node differential alone
  lua: ok 2 passed [Lua 5.5]
  luajit: ok 2 passed [luajit]
  rex: ok 2 passed [rex]
```

Pending counts are other tasks' specs (HTTP specs without `--http`, Rex-only skips). One
full run in between showed one Rex failure while task 05 had uncommitted files in the tree
(`host/popen.lua`, `spec/host_popen_spec.lua`); the next run of `--runtime rex` and the
full run above were green, and `verify/dl test multipart` never failed.

## Skipped, and why

- **Boundary from the client's host.** `protocol/rest.lua` (task 04, not my file) does not
  pass the host to `request.build`, so through a generated client the boundary comes from
  `distilled.host`'s private generator, not `host.random`. `request.build` honours `random`
  / `host` when given (specs compare whole bodies that way). Proposed one-line change in
  STATUS.md (08).
- **`distilled.file{...}` spelling.** `lua/distilled/init.lua` is task 01's; the
  constructor is `require("distilled.multipart").file` until the proposed export lands.
- **Over a real transport.** Not sent through `dl serve` with curl; transports are task
  05's, and the parser check covers the bytes request.build produces.
- **`FormDataFile()` bind.** No Smithy trait carries it in the models, so not implemented.

## Open problems

- `verify/features/generator.md` (task 06) still describes multipart as acknowledged
  unsupported; `docs/interfaces.md` should list request.build's `random`/`host` and the
  multipart module. Both are listed in STATUS.md (08).
- A file nested inside a JSON part encodes as a table of its fields (Distilled writes `{}`
  for a File); files belong at the top level of a form.
