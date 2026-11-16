# Task 08: multipart request bodies

`request.build` refuses operations whose `content_type` is `"multipart"` with an `SdkError`,
and Neon's `create_project_branch_function_deployment` is one, so the generated client has
one operation that cannot be called. You close that gap. Tasks 01-04 and 06 are finished;
task 05 (transports) is finishing in this directory. Read `AGENTS.md`, `STATUS.md` and the
done files for tasks 03 and 06 first.

Reference: the multipart branch of `buildRequest` in
`../distilled/packages/core/src/protocol-http.ts` (and `T.FormDataFile`, `HttpBody` as a
record of files), with its tests in `../distilled/packages/core/test/protocol-http.test.ts`.

## Files you own

```text
lua/distilled/multipart.lua            encoder: parts -> body string + content-type with boundary
lua/distilled/request.lua              ONLY the multipart branch (replace the SdkError refusal)
lua/distilled/gen/*                    ONLY what refers to multipart being unsupported
providers/neon.lua                     remove "multipart" from allow_unsupported
clients/neon/                          regenerate
spec/multipart_spec.lua                and the multipart cases in spec/request_spec.lua, spec/gen_*_spec.lua
verify/lib/gen_check.lua               ONLY the acknowledged-unsupported handling for multipart
verify/features/request-building.md    add the multipart section
STATUS.md (add a section "08 multipart")
```

## Requirements

1. A multipart body is built as a string (RFC 7578): each body member is a part under its
   wire name; tables are JSON-encoded parts; scalars are text parts; binary parts carry a
   filename and `application/octet-stream` unless given. Lua has no `File`/`Blob`, so
   define the value a caller passes for a file part, e.g.
   `{ filename = "a.zip", content_type = "application/zip", data = "<bytes>" }` created by
   a small constructor (`distilled.file{...}`) so it is distinguishable from an ordinary
   table, and a list of them is one part per element (the repeated-field form). Mirror
   Distilled's rules for which name and filename each part gets; where Lua cannot mirror
   them (insertion order of a record of files), sort and say so.
2. The boundary comes from `host.random` when a host is available and must not occur in
   any part's data (check and regenerate). With the fake host it is deterministic, so
   specs can compare whole bodies. Header parameter values are escaped per RFC 7578
   (quotes, CR, LF in names and filenames).
3. Binary safety: part data may contain any byte including NUL and CRLF sequences. No
   quadratic concatenation (`compat.concat`).
4. Secrets inside parts are unwrapped at the last moment like other bodies; `json.null`
   and absent members are omitted like Distilled omits null and undefined.
5. Generator: a multipart operation no longer needs `allow_unsupported`; keep that
   mechanism for anything else that may need it. Members that are files in the model
   (Smithy `Blob` targets in a multipart input) are typed as the file value in
   `types.lua`. Regenerate `clients/neon/` and make `verify/dl gen-diff neon` report
   178/178 operations built.
6. Verify against a real parser: add a spec (gated like the other HTTP specs if it needs
   the fixture server, or using `node`/`python3` directly under `lua` and `luajit`) that
   feeds the generated body to an independent multipart parser (Python's
   `email`/`cgi`-style parsing or Node's `Request.formData()`) and checks names,
   filenames, content types and exact bytes come back.

## Done means

- `verify/dl doctor` clean; `verify/dl test` green in all three runtimes; `verify/dl
  gen-diff neon` clean with 178/178.
- `tasks/08-multipart.done.md` committed with command output and anything skipped.
