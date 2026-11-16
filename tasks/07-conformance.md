# Task 07: conformance against Distilled, examples, documentation

You close the loop: prove the Lua runtime and the generated Neon client behave like
Distilled's TypeScript, write the user-facing documentation, and finish the feature map.
Tasks 01-06 are finished; read every done file in `tasks/` and `STATUS.md` first.

Read `AGENTS.md` and `../distilled-lua-plan.md` ("Conformance against Distilled", "Feature
map and proof bar").

## Files you own

```text
verify/dl: the `conform` and `live` commands only (replace the stubs)
verify/conform/                  node side (reference dumps), lua side, case generators, fixtures
verify/features/conformance.md   and any feature file that is still missing (see README index)
verify/SKILL.md                  the project-local verification skill (see below)
README.md                        the real one (replaces the stub)
docs/usage.md  docs/rex.md  docs/generating.md  docs/tracing.md
examples/                        runnable examples referenced by the docs
spec/conform_*_spec.lua
STATUS.md (your section)
```

You may fix bugs you find in any module, since every other task is finished. Keep each fix
small, with a failing test first, and list every one in your done file with the conformance
case that exposed it.

Leftovers from earlier tasks, which you now own:

- `lua/distilled/host/popen.lua`: a one-line host for stock Lua (`popen_curl`, a shell
  `sleep`, `os.time`), so the plain-Lua example in the docs works without ceremony; with specs.
- `verify/features/README.md`: index `transports.md`, `rex-host.md`, `otlp.md`,
  `generator.md` and yours; fix the stale header comment in
  `lua/distilled/trace/exporters.lua` about otlp_http.
- `distilled-lua vendor`: check that a vendored tree (runtime plus `clients/neon`) works
  from a clean directory under each runtime, using only `package.path`, and that it does
  not ship `gen/`, `testing/` or anything from `verify/`.

Task 08 (multipart request bodies) is running in this directory while you work. It owns
the multipart branch of `request.lua`, `lua/distilled/multipart.lua` and regenerates
`clients/neon/`. Leave those to it; treat the multipart operation as out of your
conformance set until `tasks/08-multipart.done.md` appears, then include it.

## Requirements

1. **`dl conform neon`** is a differential test with Distilled as the oracle. Distilled is
   installed for the Neon package (`pnpm install --filter "@distilled.cloud/neon..."` was
   run in `../distilled`; scripts that import workspace packages run with
   `node --conditions=bun`). Never modify tracked files under `../distilled/`; put the Node
   scripts in `verify/conform/` and import Distilled by path.
   - **Requests.** For every one of the 178 Neon operations and several inputs each, compare
     the request Distilled builds (`API.encodeRequest(op, input)` from
     `@distilled.cloud/core/api`, with Neon's protocol, fixed credentials and no network)
     against `request.build` through the generated Lua client: method, URL (path and query,
     compared after parsing so parameter order is reported separately from content),
     headers that carry meaning (content-type, authorization, member-bound headers), and
     body (compared as parsed JSON, or bytes for raw bodies).
   - **Inputs.** Generated from each operation's input schema with a seeded generator:
     the minimal input (required members only), a full input (every member), and a few
     random ones, including awkward values: strings needing percent-encoding and UTF-8,
     empty strings, `0`, `false`, empty arrays and objects, nested objects in query members,
     explicit nulls on nullable members, secrets on sensitive members, an undeclared extra key.
     Both sides must receive the same input; write inputs as JSON files and map them into
     each language (JSON null to `json.null` in Lua).
   - **Responses.** For a set of operations, feed canned HTTP responses through both sides
     (Distilled with a stub `HttpClient` layer; Lua with the scripted transport) and compare
     the outcome: the decoded value as JSON (secrets compared as "is redacted" plus
     unwrapped value), or the error's tag, categories, retryable mark, status, message and
     `retry_after`. Cover: success bodies, empty body, non-JSON body, each declared error by
     matcher, every status in the status map, an unmapped 5xx, an unmapped 4xx, `Retry-After`
     as seconds and as an HTTP date, and strict validation mismatches.
   - **Pagination and retry.** Scripted multi-page sequences and failure sequences through
     both, comparing the sequence of requests sent and the final result. Use fixed
     randomness and a fake clock on both sides, or compare only what does not depend on jitter.
   - Output: a summary per category, and for each mismatch the operation, the input file,
     and a field-level diff. Exit non-zero on any mismatch. A mismatch is either a bug to
     fix (with a test) or an intended difference to record in
     `verify/features/conformance.md` with the reason (for example `code` being `nil` where
     Distilled has `0`), in which case the comparison normalises it explicitly.
   - Runs under `lua`; add a mode that replays the saved reference dumps under `luajit` and
     Rex so all three runtimes are compared without Node in the loop.
2. **`dl live <provider> <op> [key=value ...]`**: an opt-in call to the real API with debug
   tracing, read-only operations by default (GET), credentials from the environment.
   There is no Neon API key on this machine, so implement it, show it failing cleanly with
   `ConfigError` when the key is absent, and mark the live run as skipped.
3. **Documentation**, written for someone who has never seen Distilled:
   - `README.md`: what it is, the 30-second example, how it relates to Distilled, status.
   - `docs/usage.md`: constructing a client, calling, errors and categories, pagination,
     retry and deadlines, secrets and credentials, validation modes, scope, the host seam
     and writing a transport.
   - `docs/rex.md`: vendoring into `~/.config/rex`, the host adapter, an action end to end,
     the limits (30-second actions, 5-second key functions, server environment, error
     strings), tracing to a file. Every snippet must be a file under `examples/` that you
     actually ran (against `dl serve` where it needs HTTP); say how it was run.
   - `docs/generating.md`: producing a model with Distilled, provider specs, `--ops`,
     vendoring, adding a provider.
   - `docs/tracing.md`: levels, exporters, span names and attributes, `dl trace`, Jaeger.
   Follow the plan's decisions; where the code differs from the plan, the docs describe the
   code and you list the difference in your done file.
4. **`verify/SKILL.md`**: the project-local verification skill for future agents, in the
   style of https://github.com/poteto/verification-skill-example (read its `SKILL.md` and
   `references/features/README.md`): when to use it, quick start, the `dl` command surface,
   the proof bar, driving conventions, and a pointer to the feature map. Make sure
   `verify/features/README.md` indexes every feature file in a sensible sweep order and
   that every file has the four headings.
5. **Full sweep.** Walk the feature map top to bottom and run what each file says. Record
   the result per feature in your done file.

## Done means

- `verify/dl doctor` clean; `verify/dl test`, `verify/dl test --http`, `verify/dl gen-diff
  neon`, `verify/dl canary` and `verify/dl conform neon` all green, the last with every
  remaining difference explained.
- `tasks/07-conformance.done.md` committed: command output, mismatch counts before and
  after, bugs fixed, intended differences, the sweep table, what is skipped and why.
