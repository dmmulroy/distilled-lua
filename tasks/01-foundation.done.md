# Task 01: foundation (done)

## What was built

| File | What |
| --- | --- |
| `spec/harness.lua` | describe/it, `eq same truthy falsy err match` plus `ne no_match raises fails_with fail pending show pcall root`; failures name the spec line and the first differing path |
| `spec/run.lua` | finds the repo root from its own path (works from any cwd, all three runtimes), reads `spec/manifest.lua`, filter by file or test name, `ok N passed` / `FAIL N failed, M passed`; exit 1 on lua/luajit, raises in Rex (`rex do` exits 1) |
| `spec/manifest.lua` | generated spec list (Rex has no `io.popen`) |
| `verify/dl` | POSIX sh driver: `doctor`, `test [filter] [--runtime R] [--json-fuzz]`, `manifest`, `fmt [--check]`, `json-bench`, `help`; stubs exit 2 for `trace expect serve rex canary jaeger gen-diff conform live` |
| `verify/lib/json_gen.mjs`, `json_diff.lua`, `json_bench.lua` | Node differential fuzz and timing |
| `lua/distilled/compat.lua` | `unpack pack load` + `pcall raise concat normalize_number is_integer_subtype` |
| `lua/distilled/json.lua` | iterative codec, `null`, array/object marks, JSON.stringify-exact output |
| `lua/distilled/errors.lua` | classes, instances, predicates, built-ins, `STATUS_MAP`, `CATEGORIES`, `match` (matchTypedError port) |
| `lua/distilled/secret.lua`, `scope.lua`, `init.lua` | per contract; `distilled.check` raises a string |
| `verify/features/{README,json,errors,secret,scope}.md` | feature map |
| specs | `json errors secret scope init compat harness` (174 tests) |

## Runtime findings (gopher-lua, Rex 0.1.0-preview.19), each reproduced with a probe

1. A `pcall` that catches an error breaks upvalues of closures in running frames
   (`local n=0; local function bump() n=n+1 end; pcall(error,"x"); bump()` leaves n = 0).
   `xpcall` is unaffected. This made the first `spec/run.lua` print `ok` under Rex after a
   failing test (the `failed` counter was an upvalue). Fixed by `compat.pcall`/`t.pcall`
   and counters in a table; regression test in `spec/compat_spec.lua`.
2. `error(msg, level)` reports one level too shallow; `compat.raise` measures and fixes it.
3. `table.concat` over more than 2,559 items raises "registry overflow" (after which
   upvalues break as in 1). `compat.concat` chunks by 500.
4. Lua call depth limit is 253 frames.
5. `math.huge` is `1.7976931348623157e308`, not infinity.
6. `tonumber("1e5")`, `tonumber("1E+5")`, `tonumber("12345678901234567890")`,
   `tonumber("1e308")` are nil; `"1.0e5"` works. `tonumber("-0")` is +0.
7. Weak tables are not collected; `string.format("%s", t)` ignores `__tostring`.

## JSON decode timing (`verify/dl json-bench`, models/neon.json, 861,884 bytes, best of 3)

| Runtime | decode | encode |
| --- | --- | --- |
| lua 5.5 | 19.9 ms | 19.9 ms |
| luajit | 11.0 ms | 11.9 ms |
| rex (gopher-lua) | 89.0 ms | 73.3 ms |

(`os.clock` is CPU time on lua/luajit and wall time in gopher-lua.)

## Commands run and their output

```text
$ verify/dl doctor; verify/dl test; verify/dl test --json-fuzz; DL_FUZZ_SEED=99 DL_FUZZ_COUNT=1000 verify/dl test --json-fuzz; verify/dl fmt --check; verify/dl json-bench
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok
exit=0
== lua
ok 174 passed [Lua 5.5]
== luajit
ok 174 passed [luajit]
== rex
ok 174 passed [rex]
== summary
  lua: ok 174 passed [Lua 5.5]
  luajit: ok 174 passed [luajit]
  rex: ok 174 passed [rex]
exit=0
ok   json-fuzz lua: 400 documents (seed 20261116) match JSON.parse/JSON.stringify
ok   json-fuzz luajit: 400 documents (seed 20261116) match JSON.parse/JSON.stringify
ok   json-fuzz rex: 400 documents (seed 20261116) match JSON.parse/JSON.stringify
exit=0
ok   json-fuzz lua: 1000 documents (seed 99) match JSON.parse/JSON.stringify
ok   json-fuzz luajit: 1000 documents (seed 99) match JSON.parse/JSON.stringify
ok   json-fuzz rex: 1000 documents (seed 99) match JSON.parse/JSON.stringify
exit=0
exit=0
Lua 5.5  neon.json: 861884 bytes, decode 19.9 ms, encode 19.9 ms (best of 3)
luajit   neon.json: 861884 bytes, decode 11.0 ms, encode 11.9 ms (best of 3)
rex      neon.json: 861884 bytes, decode 89.0 ms, encode 73.3 ms (best of 3)
exit=0
```

Failure paths of the harness itself (a temporary `spec/zz_selfcheck_spec.lua` with one
failing assertion and one runtime error, removed afterwards):

```text
$ verify/dl test selfcheck        (abridged)
== lua
FAIL spec/zz_selfcheck_spec.lua: selfcheck > fails on purpose (spec/zz_selfcheck_spec.lua:4)
  tables differ at value.a[2]
      expected: 3
      actual:   2
    whole expected: { a = { 1, 3 } }
    whole actual:   { a = { 1, 2 } }
FAIL spec/zz_selfcheck_spec.lua: selfcheck > raises on purpose
  raised: .../spec/zz_selfcheck_spec.lua:8: attempt to index a nil value (local 'x')
  stack traceback: ...
FAIL 2 failed, 0 passed [Lua 5.5]
...
Error: FAIL 2 failed, 0 passed [rex]
== summary
  lua: FAIL (exit 1) FAIL 2 failed, 0 passed [Lua 5.5]
  luajit: FAIL (exit 1) FAIL 2 failed, 0 passed [luajit]
  rex: FAIL (exit 1) Error: FAIL 2 failed, 0 passed [rex]
dl exit=1
$ rex do spec/run.lua filter=selfcheck; echo $?      -> 1
$ rex do spec/run.lua filter=nomatch-xyz; echo $?
Error: FAIL no tests ran (filter "nomatch-xyz") [rex]
1
$ touch spec/zz_new_spec.lua; verify/dl doctor
...
FAIL manifest: spec/manifest.lua is stale; run verify/dl manifest
doctor: FAIL                                          (exit 1)
$ verify/dl trace x; echo $?
dl trace: not implemented, see task 02
2
```

The fuzz also caught two real bugs while being built (gopher-lua's `math.huge`, and an
expected-side bug in the generator that let infinities through), so it does detect
differences.

## Skipped, and why

- Lua 5.1 PUC itself is not installed; luajit stands in for 5.1 semantics (as the brief
  assumes). Lua 5.2 to 5.4 are not tested.
- No network or HTTP anywhere in this task, so no fixture-server evidence applies.
- `dl canary` does not exist yet (task 05); secret non-leakage is covered by specs that
  grep for a canary value in `tostring`, concatenation, dumps and encode errors.
- Regex text matchers (`matches`) are a stub that never matches, per the contract, until
  task 03.

## Open problems

- Contract additions and deviations are listed in `STATUS.md` under 01 (code `nil` vs
  Distilled's `0`, reserved field names, `response_info.errors` / `retry_after`, extra
  helpers). The orchestrator should fold them into `docs/interfaces.md`.
- Later layers must avoid recursion over data depth and plain `pcall` because of the
  gopher-lua facts above; `t.same` itself is recursive (fine for test-sized data).
- Integers beyond 2^53 are exact on 5.5 but not on luajit/gopher-lua; that runtime
  difference is documented, not hidden.
