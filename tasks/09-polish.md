# Task 09: close the open problems

Every other task is finished and verified (read `tasks/07-conformance.done.md`, "Open
problems", and `STATUS.md`). You close the remaining loose ends. You may edit any file.
Each change is small, has a failing spec first, and must leave the whole proof bar green.

1. **Multipart boundary from the host.** `protocol/rest.lua` passes `host = ctx.host` to
   `request.build`, so the boundary uses the host's `random` (deterministic under the fake
   host). Export the file constructor as `distilled.file{ data, filename, content_type }`
   and use that name in `docs/usage.md`, the generated README and `types.lua` text;
   regenerate `clients/neon/` if generator output changes.
2. **A transport that is not a transport.** Passing the `popen_curl` or `exec_curl` module
   (a constructor) as `transport` currently fails every call with `TransportError:
   transport failed: nil`. Detect, when the client is constructed or on the first call,
   a transport whose result is a function or is neither a response table nor `nil, err`,
   and fail with a message that says what was passed and what to pass instead
   (`popen_curl()`, `exec_curl(exec)`, or `host = require("distilled.host.popen")()`).
3. **`distilled.trace.expect` is a test tool.** Move it to `distilled.testing.expect`
   (keep `verify` and every spec working), so `distilled-lua vendor` does not ship it.
4. **Stale docs.** `verify/features/generator.md` still says multipart needs
   `allow_unsupported`. Update `docs/interfaces.md` to record: `distilled.host.popen`,
   `popen_curl.sleep`, `distilled.check` raising the plain message at level 0,
   `distilled.file`, `distilled.testing.expect`, and the multipart branch of
   `request.build`. Re-read `docs/interfaces.md` top to bottom against the code and fix
   any other statement that is no longer true (the done files and `STATUS.md` list the
   deviations each task recorded).
5. **Second provider smoke test of the generator.** The generator has only ever seen Neon.
   Without adding a committed client, check it is not Neon-shaped: in `../distilled`, run
   `pnpm --filter @distilled.cloud/<pkg> run specs:fetch` and `... run convert` for two
   other OpenAPI providers of different style (suggest `planetscale` and `turso`; if a
   spec fetch fails, pick another from `ls ../distilled/packages`), copy the resulting
   `.generated-specs/*.json` to a temp directory (do not modify tracked files under
   `../distilled`), write a minimal provider spec for each in a temp directory, generate,
   and run the same checks `dl gen-diff` runs (load in all three runtimes, resolve refs,
   build every operation's request). Fix generator bugs this exposes, each with a spec
   built on a small fixture model that reproduces it. Report per provider: operations,
   shapes, anything the generator refused and why. If `pnpm install` is needed for a
   package, use `pnpm install --filter "@distilled.cloud/<pkg>..." --frozen-lockfile`.

## Done means

`verify/dl doctor`, `verify/dl test --http`, `verify/dl gen-diff neon`, `verify/dl canary
verify/lib/canary_e2e.lua`, `verify/dl conform neon` and `verify/dl conform neon --replay`
all green; `tasks/09-polish.done.md` committed with the output, the per-provider report,
and anything skipped.
