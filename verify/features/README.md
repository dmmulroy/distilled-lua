# Feature map

One file per feature area. Each has the same four headings:

- **Sub-features**: what the area does, in pieces small enough to test one at a time.
- **How a user reaches it**: the public calls.
- **Driving it with `dl`**: the commands that exercise it, and what their output proves.
- **Gotchas**: what has bitten us, especially runtime differences (lua 5.5, luajit,
  gopher-lua in Rex).

| Area | File | Owner |
| --- | --- | --- |
| JSON codec | [json.md](json.md) | task 01 |
| Errors and typed matching | [errors.md](errors.md) | task 01 |
| Secrets | [secret.md](secret.md) | task 01 |
| Scope | [scope.md](scope.md) | task 01 |
| Tracing | [tracing.md](tracing.md) | task 02 |

Other areas (request building, retry, pagination, transports, generator, Rex host)
add their file here when their task lands.

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
- Yielding across a Go function boundary (from a `table.sort` comparator or a
  `string.gsub` callback, inside a coroutine) crashes gopher-lua with a nil pointer
  dereference that takes down the whole `rex do` run. lua/luajit raise "attempt to yield
  across a C-call boundary" instead.
- `error(msg, level)` reports at `level - 1`. `compat.raise(msg, level)` corrects it.
- `table.concat` fails with "registry overflow" past about 2,500 items. Use
  `compat.concat`.
- The Lua call stack holds about 250 frames: recursion over data depth overflows. Walk
  data with explicit stacks.
- `math.huge` is the largest finite double, not infinity. Use `1/0`.
- `tonumber` rejects "1e5", "1E+5", integer strings past int64 and out-of-range values
  (returns nil); it reads "-0" as +0. `tostring(-0.0)` is "0".
- Weak tables are never collected.
