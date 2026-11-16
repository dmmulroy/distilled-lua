# Task 01: foundation

You build the base everything else stands on: the test harness, the verification driver,
and the layer-1 value modules. Other agents start from your work, so the harness and
`verify/dl` must be solid and the module APIs must match `docs/interfaces.md` exactly.

Read `AGENTS.md` first.

## Files you own

```text
stylua.toml  README.md (a short stub)  .gitignore
spec/harness.lua  spec/run.lua  spec/*_spec.lua for your modules
verify/dl  verify/lib/*  verify/features/README.md  verify/features/{json,errors,secret,scope}.md
lua/distilled/init.lua  compat.lua  json.lua  errors.lua  secret.lua  scope.lua
STATUS.md (your section)
```

## Build, in this order

1. **Harness** (`spec/harness.lua`, `spec/run.lua`), per the contract. Requirements:
   - One file each, pure Lua 5.1, runs under `lua`, `luajit` and `rex do spec/run.lua`.
   - `spec/run.lua` finds the repo root itself and sets `package.path` (so `require("distilled.json")`
     and `require("spec.harness")` work) no matter the working directory. Find out how a
     `rex do` script learns its own path and working directory; do not assume. In Rex there
     is no `io.popen`, so discover spec files without it (for example a generated
     `spec/manifest.lua`, kept current by `verify/dl`, with `dl doctor` failing when it is stale).
   - Output: one line per failing test with file, name and a readable diff of expected and
     actual; a summary line `ok N passed` or `FAIL N failed, M passed`. Non-zero exit on
     failure under `lua`/`luajit`; under Rex, make failure unmistakable to the caller
     (`rex do` exit status), and verify that it is.
   - A filter argument runs only matching spec files or test names.
2. **`verify/dl`**, a POSIX `sh` or Lua script (your choice; say why in `STATUS.md`), with:
   - `dl doctor`: checks `lua`, `luajit`, `rex` reachable (`rex whoami`), `curl`, `stylua`;
     manifest freshness; prints one line per check and exits non-zero on any failure.
   - `dl test [filter]`: runs the specs under all three runtimes, prints a per-runtime
     summary, exits non-zero if any fails. `--runtime lua|luajit|rex` runs one.
   - `dl fmt` / `dl fmt --check`: stylua.
   - Leave clearly marked stubs (exit 2, "not implemented, see task NN") for: `trace`,
     `expect`, `conform`, `gen-diff`, `serve`, `rex`, `live`, `canary`, `jaeger`.
   - `dl help` lists every command in one screen.
3. **`compat.lua`**, then **`json.lua`**. JSON is the piece most likely to have subtle bugs:
   - Test: every escape, surrogate pairs, deep nesting, empty array vs empty object in both
     directions, `null` inside arrays and objects, numbers (integers up to 2^53, negatives,
     exponents, fractions, `-0`), invalid inputs (trailing commas, bare words, unterminated
     strings, control characters, trailing garbage) each failing with an error that names
     the position.
   - Differential check against Node: write `verify/lib/json_diff.*` that generates a few
     hundred seeded random JSON documents, round-trips them through our codec under each
     runtime, and compares with `node -e` `JSON.parse`/`JSON.stringify` semantics. Wire it
     in as `dl test --json-fuzz` (or a spec that shells out only under `lua`).
   - It will parse multi-megabyte Smithy models later: avoid quadratic string building
     (collect into a table and `table.concat`), and measure decode time on a ~1 MB document
     under each runtime; record the numbers in your done file.
4. **`errors.lua`**: classes, instances, predicates, built-in classes, `STATUS_MAP`,
   `CATEGORIES`, and `errors.match`. Port from `../distilled/packages/core/src/errors.ts`,
   `category.ts`, `trait.ts` (ErrorMatcher) and `protocol-http.ts` (`matchTypedError`,
   `matchesExpression`, `atPointer`, `matcherSpecificity`). Port the matcher cases from
   `../distilled/packages/core/test/protocol-http.test.ts` and `protocol-rest.test.ts`.
   JSON pointer lookup must treat `json.null` correctly (a null value is present but never
   equals a string matcher).
5. **`secret.lua`**, **`scope.lua`**, and **`init.lua`** (`distilled.check`, `distilled.null`,
   `distilled.secret`, `distilled.scope`). `distilled.check(value, err)` returns `value` or
   raises `tostring(err)` as a string (level 2), because gopher-lua's `assert` rejects table
   messages and Rex prints a raised table as `table: 0x...`.
6. **Feature map files** for your four areas, each with the four headings: Sub-features,
   How a user reaches it, Driving it with `dl`, Gotchas.

## Done means

- `verify/dl doctor` clean; `verify/dl test` green under all three runtimes.
- `tasks/01-foundation.done.md` committed, with the command output as evidence, the JSON
  timing numbers, and anything skipped.
- Every public function in your modules matches `docs/interfaces.md`. Where you had to
  deviate, it is written in `STATUS.md` with the reason.
