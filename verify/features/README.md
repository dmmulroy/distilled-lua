# Feature map

One file per feature area. Each has the same four headings:

- **Sub-features**: what the area does, in pieces small enough to test one at a time.
- **How a user reaches it**: the public calls.
- **Driving it with `dl`**: the commands that exercise it, and what their output proves.
- **Gotchas**: what has bitten us, especially runtime differences (lua 5.5, luajit,
  gopher-lua in Rex).

Listed in sweep order: each area builds only on the ones above it, so a full sweep walks
the table top to bottom and stops at the first area that fails.

| # | Area | File | Owner |
| --- | --- | --- | --- |
| 1 | JSON codec | [json.md](json.md) | task 01 |
| 2 | Errors and typed matching | [errors.md](errors.md) | task 01 |
| 3 | Secrets | [secret.md](secret.md) | task 01 |
| 4 | Scope | [scope.md](scope.md) | task 01 |
| 5 | Tracing | [tracing.md](tracing.md) | task 02 |
| 6 | Request building | [request-building.md](request-building.md) | task 03 |
| 7 | Key mapping | [key-mapping.md](key-mapping.md) | task 03 |
| 8 | Redaction | [redaction.md](redaction.md) | task 03 |
| 9 | Response validation | [validation.md](validation.md) | task 03 |
| 10 | Retry, budget, deadline | [retry.md](retry.md) | task 04 |
| 11 | Pagination | [pagination.md](pagination.md) | task 04 |
| 12 | Credentials | [credentials.md](credentials.md) | task 04 |
| 13 | REST protocol | [rest-protocol.md](rest-protocol.md) | task 04 |
| 14 | Client and operations | [client.md](client.md) | task 04 |
| 15 | Transports (curl over popen / exec) | [transports.md](transports.md) | task 05 |
| 16 | Rex host | [rex-host.md](rex-host.md) | task 05 |
| 17 | OTLP over HTTP, Jaeger | [otlp.md](otlp.md) | task 05 |
| 18 | Generator | [generator.md](generator.md) | task 06 |
| 19 | Conformance against Distilled, `dl live` | [conformance.md](conformance.md) | task 07 |

## Full sweep

Walk the table top to bottom: run each file's "Driving it with `dl`" commands, check the
output it says proves the area, and record pass / fail / skipped (with the reason) per
area. The shortest complete sweep is:

```sh
verify/dl doctor
verify/dl test                 # areas 1-18 (all specs, three runtimes)
verify/dl test --http          # areas 15-17 against the fixture server
verify/dl expect examples/fake_service.lua --runtime rex     # area 5, 10, 11 by trace
verify/dl canary verify/lib/canary_e2e.lua                   # secrets end to end
verify/dl rex --serve examples/rex_action.lua --action distilled_demo   # area 16
verify/dl gen-diff neon        # area 18
verify/dl conform neon         # area 19 (and --replay for luajit and rex)
verify/dl jaeger check         # area 17, skipped (exit 3) without Docker
verify/dl live neon list_projects   # area 19, skipped (exit 3) without NEON_API_KEY
```

The project-level skill is `verify/SKILL.md`.

## The proof bar

See `AGENTS.md` "Verification". In short: `verify/dl doctor` clean, `verify/dl test` green
under all three runtimes, evidence is a test/trace/diff, error and empty paths exercised,
no network except the local fixture server, skipped things named.

## Runtime facts every area should know (gopher-lua, measured in Rex 0.1.0-preview.19)

- A `pcall` that catches an error **breaks closures' upvalues** in every frame still
  running: a closure made before the pcall keeps writing to a stale copy. So does any
  protected call, `xpcall` included, that catches after another protected call has
  completed inside it (`xpcall(function() xpcall(f, h); error("y") end, h)`). Use
  `compat.pcall`, built on a coroutine, which has neither bug at any depth and passes
  yields through. Keep counters that closures update in tables if in doubt.
- Yielding across a Go function boundary inside a coroutine breaks gopher-lua. Such a
  yield is one made from a `table.sort` comparator, a `string.gsub` callback, a
  metamethod, or a function run by native `pcall`/`xpcall`. The coroutine's call stack
  is corrupted, and a Go error "runtime error: invalid memory address or nil pointer
  dereference" (or "can not yield from outside of a coroutine") is raised *through*
  `coroutine.resume` into the resumer, instead of being returned as `false, msg`. An
  outer `pcall` catches it; uncaught, it ends the `rex do` run (the Rex server keeps
  running). Lua 5.1 raises "attempt to yield across metamethod/C-call boundary"
  instead, and LuaJIT/5.2+ allow the `pcall` case. Upstream: yuin/gopher-lua#545, fix
  in PR #548 (open). Never yield through native `pcall`; `compat.pcall` is safe.
  Details: `../gopher-lua-research/REPORT.md`.
- `error(msg, level)` reports at `level - 1`. `compat.raise(msg, level)` corrects it.
- `table.concat` fails with "registry overflow" past about 2,500 items. Use
  `compat.concat`.
- The Lua call stack holds about 250 frames: recursion over data depth overflows. Walk
  data with explicit stacks.
- `math.huge` is the largest finite double, not infinity. Use `1/0`.
- `tonumber` rejects "1e5", "1E+5", integer strings past int64 and out-of-range values
  (returns nil); it reads "-0" as +0. `tostring(-0.0)` is "0".
- Weak tables are never collected.
