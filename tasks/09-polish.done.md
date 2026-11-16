# Task 09: close the open problems — done

## What was built

1. **Multipart boundary from the host; `distilled.file`.**
   - `lua/distilled/protocol/rest.lua` passes `host = ctx.host` to `request.build`, so a
     client's multipart boundary comes from its `host.random`. The spec
     (`spec/neon_client_spec.lua`, the multipart case) checks the boundary equals
     `multipart.boundary(testing.random(7))` when the client gets `random = testing.random(7)`.
   - `distilled.file{ data, filename?, content_type? }` is loaded on first use (a
     `LAZY_FUNCTIONS` entry in `lua/distilled/init.lua`). It *is*
     `distilled.multipart.file`, so misuse errors keep their level. Spec: `spec/init_spec.lua`.
   - The name is used in `docs/usage.md`, `verify/features/request-building.md`, the
     generated `types.lua` (`distilled.File` doc) and the generated README. The README now
     lists the multipart operations and how to pass a file. I also fixed its construct
     example: it passed `transport = require("distilled.transport.popen_curl")`, the
     problem item 2 fixes, and now passes `host = require("distilled.host.popen")()`.
     Specs: `spec/gen_ops_spec.lua`, `spec/gen_output_spec.lua`. `clients/neon/`
     regenerated: only `README.md` and `types.lua` changed.
2. **A transport that is not a transport.**
   - The `popen_curl` and `exec_curl` modules carry
     `transport_module = "distilled.transport.<name>"`. `distilled.host.check` raises when
     one is passed as `transport` or `host.transport`, so `Class.new` raises (misuse). So
     does `trace.exporters.otlp_http{ transport = ... }`. The message says what was
     passed and what to pass instead: `require("distilled.transport.popen_curl")()`,
     `require("distilled.transport.exec_curl")(exec)`, or
     `host = require("distilled.host.popen")()`. This text is
     `distilled.host.TRANSPORT_HINT`, also used by the "no transport" `ConfigError`.
   - At call time (`rest.lua`), a transport whose result is a function, nothing
     (`nil, nil`), or a string, number or boolean is a `ConfigError` with
     `key = "transport"`. It is not retried. The message names what came back and gives
     the same hint. This catches constructors that have no marker (`popen_curl.new`, a
     user's factory).
   - Passing a function as `host` (`host = require("distilled.host.popen")`) now raises
     "host must be a table (got a function: call it, ...)".
   - Specs: `spec/client_spec.lua` ("a transport module instead of a transport"),
     `spec/rest_spec.lua` ("a transport that is not a transport", including the
     no-retry case), `spec/otlp_http_spec.lua`.
3. **`distilled.testing.expect`.** Moved with `git mv` from `lua/distilled/trace/expect.lua`
   to `lua/distilled/testing/expect.lua`. All specs, `verify/lib/trace_env.lua`,
   `verify/lib/trace_run.lua` and `verify/features/tracing.md` now use the new name.
   `vendor` already skips `testing/`. The vendor spec now checks that neither path is
   shipped (it failed before the move). `dl expect` still works: I ran
   `verify/lib/trace_example.lua` under lua and rex, and `trace_example_failing.lua`
   reports its failure as intended.
4. **Docs.**
   - `verify/features/generator.md`: multipart no longer needs `allow_unsupported`. Added
     a gotcha for the new layout rules.
   - `docs/generating.md`: the `allow_unsupported` row says nothing needs it today.
   - `docs/interfaces.md`: I re-read it top to bottom against the code. Added:
     - the top-level `distilled` module, including `distilled.check` raising the plain
       message at level 0, and `distilled.file`
     - the host defaults: Park-Miller `random` (it said `math.random`), busy-wait `sleep`,
       no default transport
     - `distilled.host.popen`, `distilled.host.rex`, the transports, `popen_curl.sleep`,
       `transport_module` and the new `ConfigError` cases
     - node-level `sensitive`
     - op fields `body_media_type` and `server`, and notes on pagination modes,
       `op.retry`, `op.span` and `output_raw`
     - all `request.build` options and its multipart branch, plus the `distilled.multipart`
       API
     - `redact.plain` / `redact.parsed`, and the validate mismatch shape plus `withhold`
     - `retry.run`'s real options and returns, and `retry.new_budget`
     - `credentials.resolve`'s `name` argument
     - `tracer:attach` / `tracer:detach`, exporters taking `(spans, meta)`, the
       `otlp_http` fields and the trace exports
     - the full `rest.new` options, `protocol.encode` / `protocol.decode`, the real `ctx`
       and the common client options
     - harness additions, and a `distilled.testing` section that includes
       `distilled.testing.expect`

     Removed the stale sentence "until task 03 lands, `matches` never matches".
5. **Second-provider smoke test.** Report below. It exposed one generator bug, now fixed
   in `lua/distilled/gen/emit.lua`: the generated Lua was not stylua-formatted when shape
   names are long.
   - A call past 100 columns now breaks its arguments the way stylua does:
     `S.ref(\n  "Name"\n)`, a single table argument hugs as `fn({ ... })`, and several
     arguments go one per line.
   - An assignment whose first line `target = {` cannot fit puts its value on the next
     line, indented one level. It stays on one line when that fits, otherwise it expands
     one level deeper. `writer.lua` now builds `errors.define` through the same path.
   - Neon output is byte-identical.
   - Specs: `spec/gen_emit_spec.lua` (both layouts; I checked the expected text with
     `stylua --check`) and `spec/gen_output_spec.lua` "long shape names". The second one
     uses the fixture model with one 96-character enum name. It checks the layout,
     loads the service, and runs `stylua --check` under lua/luajit. With the old
     `emit.lua` swapped back in, both cases fail.

## Per-provider report (smoke test, nothing committed)

How it was run:
- In `../distilled`: `pnpm --filter @distilled.cloud/<pkg> run specs:fetch` and
  `... run convert` for `planetscale` and `turso`. No `pnpm install` was needed.
  Afterwards `git status` there is clean, and the submodules sit at their recorded
  commits.
- The models were copied to `/tmp/dl09/`, with minimal provider specs in
  `/tmp/dl09/providers/`:
  - PlanetScale: `auth = { kind = "header", header = "authorization", from = "api_token" }`,
    because its service token is `<id>:<token>`; base URL `https://api.planetscale.com/v1`.
  - Turso: bearer, `https://api.turso.tech`.
  - Both use `naming.members = "wire"`. I repeated both with `"snake_case"`.
- `/tmp/dl09/check.sh <p>` repeats `dl gen-diff`'s checks:
  - generate under lua and luajit, and compare the outputs
  - `stylua --check`
  - `verify/lib/gen_check.lua` under lua, luajit and `rex do` (load, resolve every ref,
    build every operation's request)
- `/tmp/dl09/e2e.lua` drives both clients over `testing.host` in all three runtimes.

| | PlanetScale | Turso |
| --- | --- | --- |
| Model (Distilled convert) | 294 operations, 1654 model shapes | 53 operations, 259 model shapes |
| Generated | 294/294 ops, 1404 shapes, 4 error classes, 1.5 MB | 53/53 ops, 209 shapes, 4 error classes, 147 KB |
| Refs resolved | 1503 | 212 |
| Pagination | 54 ops, `page` mode (`page` / `next_page` / `data`) | 2 ops, `cursor` mode (`cursor` / `pagination.next`) |
| Traits of note | 882 labels, 321 query members, 15 rawResponse, sensitive | camelCase labels (`organizationId`), 23 `distilled.errors#bodies`, 4 errorMatchers |
| Service load | 5.4 ms lua, 5.0 ms luajit, 84-117 ms rex | 0.7 / 0.6 / 3.6-4.0 ms |
| Refused | nothing | nothing |
| Bug found | generated Lua failed `stylua --check` (long shape names); fixed | none |

Final check output (after the fix):

```text
$ /tmp/dl09/check.sh planetscale
ok   lua and luajit write identical files
ok   stylua --check
ok gen-check Lua 5.5: 1404 shapes, 1503 refs resolved, 294/294 ops built, 0 acknowledged unsupported; service load 5.4 ms; client loads
ok gen-check luajit: 1404 shapes, 1503 refs resolved, 294/294 ops built, 0 acknowledged unsupported; service load 5.0 ms; client loads
ok gen-check rex: 1404 shapes, 1503 refs resolved, 294/294 ops built, 0 acknowledged unsupported; service load 84.2 ms; client loads
$ /tmp/dl09/check.sh turso
ok   lua and luajit write identical files
ok   stylua --check
ok gen-check Lua 5.5: 209 shapes, 212 refs resolved, 53/53 ops built, 0 acknowledged unsupported; service load 0.7 ms; client loads
ok gen-check luajit: 209 shapes, 212 refs resolved, 53/53 ops built, 0 acknowledged unsupported; service load 0.6 ms; client loads
ok gen-check rex: 209 shapes, 212 refs resolved, 53/53 ops built, 0 acknowledged unsupported; service load 3.6 ms; client loads
```

The same results hold for `planetscale_snake` and `turso_snake`: snake_case member
naming, with `organizationId` becoming `organization_id`.

End to end over the scripted host (`lua`, `luajit`, `rex do`, all eight checks pass):
- PlanetScale `list_databases_items` collects two pages. The first request is `?page=1`
  (the page strategy, as in Distilled), the second `?page=2`.
- PlanetScale sends `authorization: id:tok`.
- PlanetScale `get_database` on a 404 gives `NotFound` with `code = "not_found"`.
- Turso `list_deleted_databases_items` follows `cursor=c2`.
- Turso sends `authorization: Bearer k`.

Not Neon-shaped, as far as these two show. One limit: PlanetScale's two-part service
token (`tokenId` + `token`, joined as `<id>:<token>`) cannot be stated in a provider
spec. Auth takes one option, so the user has to pass the joined string, or a `protocol`
module is needed. Its OAuth mode would be `bearer`.

## Commands and output (final tree)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  ...
ok   luajit: LuaJIT 2.1.1794386141 ...
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 ...
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test --http
== summary
  lua: ok 1091 passed [Lua 5.5]
  luajit: ok 1091 passed [luajit]
  rex: ok 1064 passed, 3 pending [rex]

$ verify/dl test
== summary
  lua: ok 1048 passed, 4 pending [Lua 5.5]
  luajit: ok 1048 passed, 4 pending [luajit]
  rex: ok 1041 passed, 7 pending [rex]

$ verify/dl gen-diff neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 2.3 ms; client loads
ok gen-check luajit: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 2.0 ms; client loads
ok gen-check rex: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 23.3 ms; client loads
gen-diff neon: ok

$ verify/dl canary verify/lib/canary_e2e.lua
ok   canary lua: key absent from stdout, stderr, trace (8 lines), 12 curl ps entries; reached the server
ok   canary luajit: key absent from stdout, stderr, trace (8 lines), 11 curl ps entries; reached the server
ok   canary rex: key absent from stdout, stderr, trace (8 lines), 12 curl ps entries; reached the server

$ verify/dl conform neon
node: 904 requests from Distilled (2 failed to build)
== conform neon [Lua 5.5]
  members    178 cases:  178 match (0 with intended differences), 0 mismatch, 0 skipped
  requests   904 cases:  904 match (1 with intended differences), 0 mismatch, 0 skipped
  responses  977 cases:  977 match (67 with intended differences), 0 mismatch, 0 skipped
  flows       36 cases:   36 match (11 with intended differences), 0 mismatch, 0 skipped
conform: ok

$ verify/dl conform neon --replay
== conform neon [Lua 5.5] ... conform: ok
== conform neon [luajit] ... conform: ok
== conform neon [rex]
  members    178 cases:  178 match (0 with intended differences), 0 mismatch, 0 skipped
  requests   904 cases:  904 match (1 with intended differences), 0 mismatch, 0 skipped
  responses  977 cases:  977 match (67 with intended differences), 0 mismatch, 0 skipped
  flows       36 cases:   36 match (11 with intended differences), 0 mismatch, 0 skipped
conform: ok
```

Pending specs:
- HTTP specs without `--http`.
- Rex-only skips: the CLI and `stylua` cases, which need io.popen.
- The Node differential, which needs node.

"2 failed to build" is Distilled's side and the same as in task 07: those cases are
requests that Distilled itself refuses, and the comparison counts them as matches.

## Skipped, and why

- **The PlanetScale and Turso clients are not committed** (the brief says not to add
  one), and there are no conformance runs for them: `verify/conform/node/*.mjs` bind
  only Neon.
- **Live API calls:** none (rule 5).
- **A file nested in a JSON part** still encodes as a table of its fields, as task 08
  noted. Not in this brief.

## Open problems

- `verify/conform/node/*.mjs` bind only Neon. A second provider needs its import there
  before `dl conform <provider>` can run.
- Provider specs cannot compose a credential from two options (PlanetScale's
  `<tokenId>:<token>`). Candidates: an `auth.kind = "header"` with a template, or a
  provider `protocol` module.
- `STATUS.md` sections 01-08 still list their proposals as proposals. Those proposals
  are now recorded in `docs/interfaces.md`. I left those sections alone because each
  task owns its section.
