# Task 06: the generator

You build the generator: a Lua program that reads a patched Smithy JSON model plus a small
provider spec and writes a Lua client. Tasks 01-04 are finished; read their done files and
`STATUS.md` first. Task 05 (transports, Rex host) runs at the same time as you in this
working tree, so stay inside your files.

Read `AGENTS.md`; `../distilled-lua-plan.md` ("Using distilled-lua as a tool", "Consuming a
generated client"); `docs/interfaces.md` ("Schema nodes", "Operation and service
descriptors"); sections 3.2 to 3.6 of `../distilled-deep-dive.md`.

Your input fixture is `models/neon.json`: the Neon model exactly as Distilled's `convert`
produced it, patches applied (178 operations, 822 shapes). Reference for behaviour:
`../distilled/packages/dev/src/codegen/generator.ts` (the seven steps, `errorCategories`,
member binding cascade, pagination validation), `members.ts`, `graph.ts`, `operations.ts`,
`pagination.ts`, `telemetry.ts`, and `../distilled/packages/neon/scripts/generate.ts`,
`src/protocol.ts`, `src/credentials.ts`, `src/errors.ts` for what Neon's hand-written glue
does. The TypeScript it generates for comparison: `../distilled/packages/neon/src/services/neon.ts`.

## Files you own

```text
lua/distilled/gen/init.lua        generate{ model, provider, ops, out, telemetry } -> files
lua/distilled/gen/model.lua       load, index, reachability, validation of the Smithy model
lua/distilled/gen/naming.lua      snake_case operation names, collisions
lua/distilled/gen/shapes.lua      Smithy shape -> schema node source
lua/distilled/gen/errors.lua      error shapes -> error class source (categories, matchers)
lua/distilled/gen/ops.lua         operations -> op descriptors
lua/distilled/gen/types.lua       LuaLS ---@meta definitions
lua/distilled/gen/emit.lua        Lua source writer (deterministic, stylua-clean)
lua/distilled/gen/provider.lua    provider spec loading and validation
bin/distilled-lua                 CLI: generate, vendor
providers/neon.lua
clients/neon/                     the generated Neon client, committed
verify/dl: the `gen-diff` command only (replace the stub)
verify/lib/gen_*    verify/features/generator.md
spec/gen_*_spec.lua   spec/neon_client_spec.lua
STATUS.md (your section)
```

## Requirements

1. **CLI.** `bin/distilled-lua generate --model <file> --provider <file> --out <dir>
   [--ops a,b,c] [--no-telemetry]` and `bin/distilled-lua vendor --out <dir>` (copies the
   runtime modules a client needs: everything under `lua/distilled/` except `gen/` and
   `testing/`). Runs under `lua` and `luajit`; it does not need to run inside Rex.
2. **Output layout** for `--out clients/neon`:

   ```text
   clients/neon/init.lua      the client class (Client.define + provider protocol); what `require("neon")` returns
   clients/neon/service.lua   shapes, errors, ops as data (may be split into several files if large)
   clients/neon/types.lua     ---@meta LuaLS definitions: request/response classes, client methods
   clients/neon/README.md     generated: how to construct the client, operation list with one-line docs
   ```

   `package.path` entries `<dir>/?.lua;<dir>/?/init.lua` with `<dir>` the parent of `neon/`
   must make `require("neon")` work. Requiring the client must be cheap: measure load time
   and memory for the full Neon client under each runtime, and if it is slow, make shape
   construction lazy (for example a function per shape resolved on first `ref`). Record numbers.
3. **Provider spec** (`providers/neon.lua`): name, base URL (with an option and an
   environment variable to override it), auth (`bearer` from option `api_key`, default from
   env `NEON_API_KEY`), tags for the unknown and parse errors (`UnknownNeonError`,
   `NeonParseError`), optional `error_envelope`, `status_map`, `classify_error`, naming
   policy. Validate it and reject unknown keys. Keep it declarative; an escape hatch for a
   hand-written protocol module is enough for anything else.
4. **Shapes to schema nodes**, covering every shape type and trait in the model: structure,
   list, map, union, enum, intEnum, prelude scalars (`String`, `Boolean`, `Integer`, `Long`,
   `Float`, `Double`, `BigInteger`, `BigDecimal`, `Timestamp`, `Blob`, `Document`, `Unit`);
   member bindings in the cascade order label, query, header, payload, body; `jsonName` as
   `wire`; `required`; `com.distilled.openapi#nullable`; `smithy.api#sensitive`;
   `com.distilled.openapi#rawResponse` (the output is the member's value: `output_raw`);
   `com.distilled.openapi#additionalProperties` (`open`); `com.distilled.openapi#contentType`;
   greedy labels from the URI; recursive shapes through `ref`.
   Run `jq` over `models/neon.json` to list every trait id in use and make sure each is
   either handled or deliberately ignored with a comment saying why. An unknown trait id in
   the `smithy.api#http*`, `com.distilled.openapi#` or `distilled.` namespaces must fail
   generation, so a new model feature cannot be silently dropped.
5. **Errors:** error shapes become classes with categories from `errorCategories`
   (`smithy.api#httpError`, `smithy.api#retryable`, `distilled.errors#categories`),
   matchers from `com.distilled.openapi#errorMatchers`, declared members as fields. Service
   errors are inherited by every operation. Regex matchers must compile with
   `distilled.regex` or generation fails.
6. **Operations:** snake_case name from the model's operation name (`GetProject` ->
   `get_project`; handle acronyms and digits sensibly: `GetOAuthClient`, `ListIPAllowlist`,
   `GetV2Thing`; write the cases down as tests), failing on a collision or a Lua keyword;
   `method`, `uri`, `code`; `errors`; `pagination` from `smithy.api#paginated` with
   Distilled's validation (a trait missing a field its mode reads fails generation); `retry`
   from `distilled.retry#policy`; `span` and service `telemetry` from the telemetry traits
   unless `--no-telemetry`.
7. **`--ops`:** keep only the named operations and the shapes and errors they reach. An
   unknown name fails with the nearest matches suggested.
8. **Types** (`types.lua`): `---@class` per structure with `---@field` lines (optional and
   nullable shown), aliases for enums and unions, and a `---@class neon.Client` with one
   documented method per operation (and the `_pages` / `_items` variants with the item
   type), using the model's documentation as the description. `lua-language-server` is not
   installed, so correctness here is by careful reading of the LuaLS annotation
   documentation (fetch it); note that it is unchecked by a tool.
9. **Fail early:** every problem (dangling target, unsupported trait, bad pagination trait,
   name collision, regex that does not compile, provider spec error) stops generation with
   a message that names the shape. Nothing is emitted that can fail at call time for a
   reason the generator could have seen.
10. **Deterministic output:** same input, byte-identical output, formatted so that `stylua
    --check` passes (or excluded from stylua with a stated reason if the files are data-like
    and huge). No timestamps in the files; a header comment names the model's hash.
11. **`dl gen-diff <provider>`:** regenerates into a temp directory and diffs against the
    committed `clients/<provider>/`; then loads the generated client under all three
    runtimes, resolves every `ref`, builds a request for every operation from a minimal
    synthesized input (required members filled with placeholder values of the right type)
    through `request.build`, and reports any failure by operation name.
12. **`spec/neon_client_spec.lua`:** the generated Neon client over the scripted transport:
    `get_project` success and `NotFound`; `list_projects_items` across two pages with the
    cursor; a sensitive output member comes back as a secret; the bearer header is sent; an
    operation with a `rawResponse` output; one with a request body; base URL override.
    Compare a handful of built requests by hand against what
    `../distilled/packages/neon/src/services/neon.ts` declares for the same operations.

## Done means

- `verify/dl doctor` clean; `verify/dl test` green in all three runtimes; `verify/dl gen-diff
  neon` clean (no diff, all 178 operations build a request under all three runtimes).
- `clients/neon/` committed.
- `tasks/06-generator.done.md` committed with the command output, load time and memory
  numbers, the list of traits handled and ignored, and anything skipped.
