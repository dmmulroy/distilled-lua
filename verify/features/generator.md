# Generator (`distilled.gen`, `bin/distilled-lua`)

## Sub-features

- **Model** (`gen/model.lua`, `gen/json_ordered.lua`): loads Smithy JSON keeping key
  order (members, union arms, enum values are declared in order); indexes shapes,
  the service and operations (sorted by name); synthesizes `<Op>Request`/`<Op>Response`
  for Unit I/O (`ensureNamedIo`); appends the service's errors to every operation
  (`inheritServiceErrors`); turns request-only `"true"|"false"` enums into string-encoded
  booleans (`booleanStringEnums`); FNV-1a hash of the model text for the headers.
- **Validation**: dangling targets, unknown prelude shapes, local-name clashes across
  namespaces, errors without `smithy.api#error`, mixins, resources, and the **trait
  audit** (`gen/traits.lua`): every trait id is handled, ignored with a reason, or fails
  (`fail = why`); an unknown id under `smithy.api#http*`, `com.distilled.openapi#`,
  `com.distilled.telemetry#`, `com.distilled.grpc#` or `distilled.` fails, others warn.
- **Shapes** (`gen/shapes.lua`): member names (wire or snake_case, `memberBases`
  fallback), bindings label -> query -> header -> status -> payload -> body, wire names
  (`smithyWireName`), required (+ `@default` in response-only shapes, + paginated items
  root), nullable, sensitive (member or target shape), string_encoded, greedy labels from
  the URI, open structs, enum/intEnum, list/map, unions with `unionDiscriminator`. Named
  shapes are registry entries; members refer by `S.ref`, so recursion is free.
- **Errors** (`gen/errors.lua`): `errorCategories` exactly as Distilled (404 ->
  BadRequestError), retryable/throttling, matchers validated key by key, every `matches`
  regex compiled with `distilled.regex`, declared members as fields.
- **Operations** (`gen/ops.lua`): http trait (method, uri, code, contentType,
  bodyMediaType), URI placeholders vs label members, raw-response outputs (`output_raw`,
  Blob = bytes), pagination translated to snake_case and validated (fields per mode as
  `CORE_STRATEGY_FIELDS`; token, items and page size must be members), retry policy
  (`retryPolicyOf`), telemetry compression (`telemetryRules` / `telemetryLines`).
- **Naming** (`gen/naming.lua`): snake_case with acronyms, digits and a word list
  (`OAuth`, ...); collisions (also with `_pages`/`_items`), keywords, client methods;
  `--ops` suggestions by edit distance.
- **Output** (`gen/writer.lua`, `gen/types.lua`, `gen/emit.lua`): `service.lua` (data),
  `init.lua` (Client.define + rest.new), `types.lua` (LuaLS), `README.md`. Deterministic,
  stylua-clean (inline when a table fits 100 columns, else one entry per line), no
  timestamps, header names the model hash.
- **Provider spec** (`gen/provider.lua`, `providers/neon.lua`): strict, declarative.

## How a user reaches it

```sh
bin/distilled-lua generate --model models/neon.json --provider providers/neon.lua \
  --out clients/neon [--ops get_project,list_projects] [--no-telemetry]
bin/distilled-lua vendor --out vendor        # runtime modules, without gen/ and testing/
```

then `package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path` and
`require("neon")`. From Lua: `require("distilled.gen").generate{ model, provider, ops,
telemetry }` returns the files.

## Driving it with `dl`

- `verify/dl gen-diff neon`: regenerates with lua and luajit (must be identical), diffs
  against the committed `clients/neon/`, runs `stylua --check` on the fresh output, then
  `verify/lib/gen_check.lua` under lua, luajit and rex: loads the service and the client,
  resolves every `ref`, builds a request for every operation from a synthesized minimal
  input (`verify/lib/gen_input.lua`), reports failures by operation.
- `verify/dl test gen_` runs the generator specs on `verify/lib/gen_fixture.lua` (a small
  model with every shape type and trait); `gen_neon` regenerates the real Neon client in
  every runtime and compares bytes; `neon_client` drives the generated client over the
  scripted transport.
- `lua verify/lib/gen_load_bench.lua $PWD $PWD/clients neon` (or `rex do ... root= dir=
  provider=`): load time and memory of the runtime, the service data and the class.

## Gotchas

- Lua tables lose key order, so the generator has its own ordered JSON decoder; the
  emitter orders record keys by `emit.FIELD_ORDER` then name.
- stylua keeps an expanded table expanded and an inline one inline; the emitter's only
  rule is "inline if the line fits in 100 columns", so its output is already formatted.
  Quoting follows `AutoPreferDouble` (single quotes when the string has `"` and no `'`).
- Long shape names (PlanetScale's `PaginatedDatabaseDeployRequest...` names, task 09)
  need two more stylua layouts, both in `gen/emit.lua` with specs in
  `spec/gen_emit_spec.lua`: a call past the width breaks its arguments out
  (`S.ref(\n  "Name"\n)`, one table argument hugs `fn({ ... })`), and an assignment
  whose first line `target = {` cannot fit hangs its value on the next line.
  Neon's names never needed either, so its output is unchanged.
- Lua 5.5 makes `for` loop variables constant: never assign to one.
- gopher-lua's `table.concat` overflows past ~2,500 items: the generator uses
  `compat.concat` (the whole Neon generation runs in Rex in about a second).
- `CreateProjectBranchFunctionDeployment` is multipart. Since task 08 `request.build`
  encodes multipart bodies, so it generates and builds like any other operation (no
  `allow_unsupported`; gen-check requires a `multipart/form-data; boundary=` content
  type). `provider.UNSUPPORTED` is empty now, and a stale `allow_unsupported =
  { "multipart" }` fails generation and says to remove it (`provider.CLOSED_GAPS`).
  Its Blob members are typed `distilled.File|string` in `types.lua`, and the README lists
  the multipart operations with `distilled.file{...}`.
- `status_map` in a provider spec names tags; `rest.new` takes classes and replaces the
  whole map, so the generated `init.lua` copies `errors.STATUS_MAP` and sets entries.
- `types.lua` is checked by reading only: lua-language-server is not installed.
