---
name: verify-distilled-lua
description: "Verify changes to distilled-lua (the Lua runtime, the generator, generated clients) with verify/dl: specs under lua, luajit and gopher-lua (Rex), traces, the local HTTP fixture server, the secret canary, generator diffs and the differential test against Distilled. Use before claiming any change to lua/, bin/, providers/, clients/ or verify/ works."
disable-model-invocation: true
---

# Verify distilled-lua

`verify/dl` is the driver: plain POSIX `sh` that glues the interpreters, the fixture
server and Node together; heavier logic lives in `verify/lib/*.lua` and
`verify/conform/`. `verify/dl help` is canonical for commands and flags.

The library must behave the same on three runtimes: `lua` (5.5 here), `luajit`, and
gopher-lua inside Rex (`rex do`). Rex is the real target and the one that differs most,
so evidence from `lua` alone does not count.

## When to use

- Before saying a change to `lua/distilled/`, `bin/`, `providers/`, `clients/` or
  `verify/` works.
- After regenerating a client or updating the model.
- For a broad regression sweep: walk `features/README.md` top to bottom.

## Quick start

```bash
verify/dl doctor                      # interpreters, curl, a reachable Rex, stylua, node, spec manifest
verify/dl test                        # every spec under lua, luajit and rex
verify/dl test retry_                 # one area (a filter on spec file names)
verify/dl test --http                 # also the HTTP specs, against a private dl serve
verify/dl conform neon --replay       # behaviour vs Distilled, saved dumps, all three runtimes
```

## Command surface

- **Health:** `doctor`, `manifest` (regenerate `spec/manifest.lua`; commit it with a new
  spec), `fmt [--check]`.
- **Specs:** `test [filter] [--runtime R] [--http] [--json-fuzz]`.
- **Traces:** `trace <script> [--level debug|operation] [--runtime R]`,
  `trace --file <otlp.jsonl>`, `expect <script>` (asserts on the spans the script's
  returned function checks).
- **HTTP:** `serve start|stop|url|run <cmd>` (scriptable fixture server: status
  sequences, delays, headers, binary bodies, dropped connections), `rex [--serve] <script>
  [--action NAME] [k=v]` (runs `rex do` with this repo on `LUA_PATH`; never touches
  `~/.config/rex`).
- **Secrets:** `canary <script> [--runtime R]`: fake key, debug tracing; fails if the
  key appears in stdout, stderr, the trace, temp files or `ps` samples.
- **Generator:** `gen-diff <provider>`: regenerate under lua and luajit, diff with
  `clients/<provider>`, stylua-check, load under all runtimes, resolve every ref, build a
  request for every operation.
- **Oracle:** `conform <provider> [--replay] [--runtime R] [--only members,requests,responses,flows]`:
  the differential test against Distilled's TypeScript runtime.
- **Last mile:** `live <provider> <op> [--write] [k=v]`: one real API call, debug traced,
  GET only by default, key from the environment; exit 3 means skipped (no key).
- **Collector:** `jaeger start|stop|url|check` (Docker; exit 3 when Docker is down).

Examples:

```bash
verify/dl trace examples/fake_service.lua --level debug --runtime rex
verify/dl expect examples/fake_service.lua --runtime luajit
verify/dl canary verify/lib/canary_e2e.lua
verify/dl rex --serve examples/rex_action.lua --action distilled_demo
verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
  NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon lua examples/plain_lua.lua'
verify/dl gen-diff neon
verify/dl conform neon                 # regenerates the Distilled dumps (needs ../distilled installed)
DL_CONFORM_VERBOSE=1 lua verify/conform/compare.lua "$PWD" neon    # also print intended differences
```

## Proof bar

A claim that something works needs all of:

1. `verify/dl doctor` is clean (a stale `spec/manifest.lua` fails it).
2. It ran under all three runtimes (`verify/dl test`, not `lua spec/run.lua`).
3. The evidence is a spec, a trace (`dl trace` / `dl expect`), a conformance diff or a
   fixture-server exchange, not "it returned something".
4. The error, empty and retry paths the change can affect are exercised, not only
   success.
5. No live API calls and no network in tests, except the local fixture server
   (`dl serve`); `dl canary` finds nothing when secrets or tracing are touched.
6. Anything you could not verify is named as skipped, with the reason and the closest
   path that was covered (no Neon key: `dl live` skipped; Docker down: `dl jaeger`
   skipped).

When a behaviour also exists in Distilled, `verify/dl conform neon` is the strongest
evidence: it diffs requests, outcomes, retry timing and pagination against the
TypeScript runtime. A new difference is either a bug (fix it, add a spec) or an intended
difference recorded in `verify/conform/intended.lua` and
`features/conformance.md` with its reason.

## Driving conventions

- Write tests in `spec/<area>_spec.lua` on `spec/harness.lua`; run them with
  `verify/dl test <area>`. Use `distilled.testing.transport` (scripted responses,
  recorded requests) and `distilled.testing.host` (fake clock: `sleep` advances `now`
  instantly, seeded `random`) so retry and deadline tests take milliseconds.
- HTTP specs gate on `require("verify.lib.serve").url()` and call `t.pending` without it;
  `verify/dl test --http` provides the server.
- Never use plain `pcall` (gopher-lua corrupts upvalues): `compat.pcall`, or `t.pcall`
  in specs. Never recurse over data depth (about 250 frames in Rex). `table.concat` past
  ~2,500 items fails in Rex: `compat.concat`. The full list is in `features/README.md`.
- Prefer a trace over prints: `dl trace` shows what the code did, per attempt.
- Other agents may share the tree: run your own area with a filter while working, and
  commit with explicit paths.
- Do not restart the Rex server or edit `~/.config/rex`; `dl rex` and `rex do` scripts
  are enough.

## Feature map

The behaviour inventory lives in [`features/`](features/README.md), one file per area in
sweep order, each with the same four headings: `Sub-features`, `How a user reaches it`,
`Driving it with dl`, `Gotchas`. Open the file for the area you changed and drive what it
lists; for a broad sweep walk the index top to bottom.
