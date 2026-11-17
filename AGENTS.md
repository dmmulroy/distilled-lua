# distilled-lua

A standalone Lua library and generator that turns Distilled's patched Smithy models into Lua
API clients. Several agents build it in phases; an orchestrator assigns one task brief per
agent (`tasks/NN-name.md`) and checks the result.

## Read first

1. Your task brief in `tasks/`. It names the files you own and what "done" means.
2. `../distilled-lua-plan.md`: the design. It is authoritative for behaviour and naming.
3. `docs/interfaces.md`: the contracts between modules. Do not change a contract on your
   own; see "When something does not fit".
4. `../distilled-deep-dive.md`: how Distilled (the TypeScript original) works.
5. `../distilled/packages/core/src/`: the reference implementation. When the plan says a
   module "replaces" a Distilled one, read that file and port its behaviour, including the
   edge cases its comments explain. Read only; never modify anything under `../distilled/`.

## Hard rules

- **Lua 5.1 baseline, pure Lua, no dependencies.** The same file must run on `lua` (5.5
  here), `luajit`, and gopher-lua (Rex). So: no `goto`, no `//`, no bitwise operators, no
  integer/float distinction, no `table.unpack` (use the compat shim), no `utf8` library, no
  `<close>`, no `string.pack`, no C modules.
- **The core never names `rex`.** Only `lua/distilled/host/rex.lua` may. Nothing in the core
  may call `io.popen` or `os.execute` either, except `transport/popen_curl.lua`.
- **Expected failures return `nil, err`** where `err` is an error table from
  `distilled.errors`. Library code never raises for a runtime failure. `error()` is only for
  misuse (a wrong argument type), with level 2.
- **Never put a secret in an error, log line, span attribute or process argument.**
- **Modules return a local table.** No globals. `snake_case` identifiers. Named arguments
  are a single table.
- **Fail early in the generator**, never at call time.
- Format with `stylua` (config in `stylua.toml`). Keep modules small and commented where the
  reason is not obvious, especially where a behaviour is copied from Distilled.

## Facts about the runtimes (measured on this machine)

| | `lua` 5.5 | `luajit` | gopher-lua via `rex do file.lua` |
| --- | --- | --- | --- |
| `unpack` / `table.unpack` | no / yes | yes / no | yes / no |
| `loadstring` | no (`load`) | yes | yes |
| `os.clock()` | CPU time | CPU time | wall time |
| `io.popen`, `os.execute` | yes | yes | raise an error |
| `assert(nil, table)` | passes table | passes table | fails: "string expected, got table" |
| `setfenv` | no | yes | yes |

In Rex (gopher-lua): `rex.exec(argv, { stdin, timeout, cwd, env })` returns
`{ code, ok, stdout, stderr, timed_out }`; `rex.sleep(seconds)` exists in `rex do` scripts
only; `rex.json` is lossy and must not be used by the library. A script's return value is
printed as JSON. Rex reference: `curl -s https://www.superlogical.com/rex/docs/reference/lua.md`.

### gopher-lua defects that library code must work around (found in task 01, each reproduced)

- **Never use plain `pcall`.** A `pcall` that catches an error corrupts the upvalues of
  closures in running frames. Use `compat.pcall` (built on `xpcall`); in specs `t.pcall`.
- `error(msg, 2)` reports one level too shallow: use `compat.raise(msg, 2)`.
- `table.concat` fails past about 2,500 items: use `compat.concat`.
- The call stack is about 250 frames: **no recursion over data depth**. Walk values and
  schemas with an explicit stack, or bound the depth and fail with a clear error.
- `math.huge` is the largest finite double, not infinity (`1/0` is).
- `tonumber` rejects `"1e5"` and large digit strings: parse wire numbers with `json.decode`.
- Weak tables are never collected: a weak-keyed cache is a plain cache there. Only cache
  on long-lived keys (schema nodes, classes), never on per-call values.
- `string.format("%s", t)` ignores `__tostring`: call `tostring(t)` first.
- **A multiple assignment to locals is sequential** (found in task 14): `a, b = b, a`
  gives `b, b`. Use a temporary (`local tmp = a; a = b; b = tmp`). Table fields
  (`t[1], t[2] = t[2], t[1]`) are fine.

`STATUS.md` (section 01) has the full list and the `rex do` script facts. Read it.

Do not restart the Rex server, do not edit anything under `~/.config/rex`, and do not touch
other Rex sessions or panes.

## Verification

`verify/dl` is the driver (built in task 01). The proof bar for any claim that something works:

1. `verify/dl doctor` is clean.
2. It ran under all three runtimes: `verify/dl test` (not only `lua`).
3. The evidence is a test, a trace, a conformance diff or a fixture exchange, not "it
   returned something".
4. Error, empty and retry paths the change can affect are exercised, not only success.
5. No live API calls and no network in tests, except against the local fixture server.
6. Anything you could not verify is named as skipped, with the reason.

Write tests in `spec/<area>_spec.lua` on the harness in `spec/harness.lua`. Port the relevant
cases from `../distilled/packages/core/test/*.test.ts` where they exist; they encode real bugs.

## Working with other agents

- **Own only the files your brief lists.** Read anything; write only yours. If you need a
  change in a file you do not own, describe it in `STATUS.md` under your task and work
  around it.
- **Commit small and often, with explicit paths:** `git add <paths>` then
  `git commit -m "<area>: <what>"`. Never `git add -A` or `git add .`; other agents share
  this working tree and `git status` will show files that are not yours. Never rewrite
  history, never `git stash`, never `git checkout` someone else's files.
- **`STATUS.md`** has one section per task. Keep yours current: done, in progress, blocked,
  decisions you made that others should know. Edit only your section.
- **When something does not fit** (a contract in `docs/interfaces.md` is wrong or missing a
  case): write the problem and your proposed change in your `STATUS.md` section, pick the
  most conservative assumption, and continue. The orchestrator updates the contract.
- **When you are finished:** run the full proof bar, write `tasks/NN-name.done.md` (what was
  built, the exact commands you ran with their output, what is skipped and why, open
  problems), commit it, and stop. Do not start work outside your brief.
- If you are stuck for more than a few attempts on one problem, write it down in
  `STATUS.md` and move to the next item in your brief.
