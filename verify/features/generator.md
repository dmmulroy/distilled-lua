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
bin/distilled-lua generate --model models/neon/neon.json --provider providers/neon.lua \
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

## Large models (task 18)

A service whose single `service.lua` would pass `writer.SINGLE_FILE_MAX_BYTES` (512 KB)
or `writer.SINGLE_FILE_MAX_CONSTANTS` (20,000, emit.scan's upper bound) is **split**:

```text
clients/<lua>/[<model>/]
  init.lua, types.lua, README.md     unchanged
  service.lua                        errors, a shape index, the lazy registry, the op loader
  service/shapes_001.lua ...         ~128 KB each (writer.CHUNK_BYTES / CHUNK_CONSTANTS 4,000)
  service/ops_001.lua ...            every one loaded by service.lua
  service/errors_001.lua ...         only when the errors alone pass CHUNK_BYTES
```

- `service.ops` stays a plain, complete table (Client.define and `pairs` are unchanged;
  an op descriptor is small: Rex compiles 1,000 of them in ~33 ms when split).
- `service.shapes` is a registry with an `__index` metamethod: the first lookup parses
  the index (one long-string constant, `"<file> <name>"` per line), and a lookup of a
  shape not loaded yet requires its whole file and `rawset`s its shapes. An unknown name
  is nil; a missing file raises (as a missing module does). **`pairs(service.shapes)`
  sees only loaded shapes**: tools that need all of them iterate
  `service.shape_chunks` (module names, present only on a split service) as
  `verify/lib/gen_check.lua` does.
- Shapes are packed in the order the operations reach them (depth-first from each
  operation, operations by method name), then sorted by name inside a file, so one call
  loads one file in 9 of the 10 models below (Stripe's `create_account`: 5 of 37).
- Small models are byte-identical (Neon 249 KB / 5,635 constants, every Hetzner model).
  `--ops` selections are planned first, so a few ops of a big model fit one file again.
- The files' module names come from `...` (`<client>.service`), so a vendored client
  under any directory loads. `bin/distilled-lua` creates `files.dirs` and removes a
  generated client's old `service/` before writing, so no stale chunk stays behind.
- Generation fails early when one statement needs more than `writer.MAX_CONSTANTS`
  (60,000) constants or nests deeper than `writer.MAX_DEPTH` (100).

### Limits measured (`verify/lib/lua_limits.lua`, compile only)

| Limit | lua 5.5 | luajit 2.1 | gopher-lua (Rex) |
| --- | --- | --- | --- |
| constants per function | none hit at 65,537 | **65,536** (strings, numbers, table templates each) | 262,143 (`too many constants`; measured once, 107 s to compile) |
| compile time, 65,536 distinct strings in one function | 19 ms | 13 ms | **7.3 s** (quadratic: 4k 29 ms, 16k 0.4 s, 32k 1.6 s) |
| one constructor of 100,000 strings (an enum) | 20 ms | 11 ms (template, no limit) | 17 s |
| locals per function | 200 | 200 | 200 |
| upvalues per closure | 199 ok (the 200 locals cap first) | **60** | 199 ok |
| nesting of tables | 190 ok, 199 C stack overflow | 190 ok, 199 too many syntax levels | 200 ok, 250 register overflow |
| a 16 MB long string | 55 ms | 36 ms | 52 ms (lexing strings is cheap) |

gopher-lua dedups constants with a linear scan, so one function's compile time is
quadratic in its distinct constants: infisical's 15 MB `service.lua` took 10.6 s in Rex,
the same shapes in 113 files of 128 KB take 0.57 s **all loaded**. Lua code itself
compiles at ~25 MB/s once functions are small; lazy shapes take that off `require`.

### Before and after, the 10 largest models

Dummy provider spec (bearer, `naming.members = "wire"`), `sh verify/lib/big_models.sh
<pkg>/<model> ...` (before = `c09d560`, main when task 18 started). "Sanitized": the
model fails generation for another task's reason (AWS query protocol and errors, Azure
`apiVersion`, Cloudflare pagination), so `verify/lib/bench_sanitize.mjs` patched it
(routes, traits; no operation dropped) to measure its size. github/webhooks has no
operations. Rex has no heap counter: its column is the `rex do` process's maximum RSS
(Neon, single file: 24 ms, 54 MB).

| Model | Model MB | Ops | Before: service.lua | After: service.lua + service/ | types.lua | Generate, luajit (time, max RSS) | Generate, lua |
| --- | ---: | ---: | ---: | --- | ---: | --- | --- |
| infisical/infisical | 34.9 | 2527 | 15.0 MB | 2.2 MB + 121 files, 15.0 MB | 12.2 MB | 6.11 s, 769.8 MB → 6.70 s, 814.6 MB | 8.11 s → 8.90 s |
| cloudflare/zero_trust (sanitized) | 16.6 | 605 | 9.0 MB | 1.8 MB + 73 files, 9.1 MB | 7.8 MB | 3.15 s, 337.9 MB → 3.48 s, 402.6 MB | 4.10 s → 4.47 s |
| stripe/stripe | 16.2 | 648 | 4.7 MB | 0.8 MB + 39 files, 4.7 MB | 7.1 MB | 2.19 s, 287.3 MB → 2.43 s, 314.2 MB | 2.94 s → 3.14 s |
| datadog/v2 | 11.4 | 1760 | 3.8 MB | 0.5 MB + 32 files, 3.9 MB | 4.3 MB | 1.90 s, 229.2 MB → 2.02 s, 267.5 MB | 2.39 s → 2.62 s |
| azure/network (sanitized) | 7.7 | 830 | 2.5 MB | 0.3 MB + 21 files, 2.5 MB | 2.9 MB | 1.02 s, 142.0 MB → 1.11 s, 168.6 MB | 1.39 s → 1.53 s |
| elasticsearch/elasticsearch | 7.5 | 819 | 2.2 MB | 0.3 MB + 19 files, 2.3 MB | 3.8 MB | 1.08 s, 146.8 MB → 1.19 s, 179.9 MB | 1.45 s → 1.61 s |
| aws/ec2 (sanitized) | 7.0 | 823 | 1.5 MB | 0.1 MB + 14 files, 1.5 MB | 3.3 MB | 0.76 s, 120.5 MB → 0.83 s, 128.5 MB | 1.01 s → 1.12 s |
| cloudflare/radar (sanitized) | 6.8 | 281 | 2.2 MB | 0.4 MB + 18 files, 2.2 MB | 2.3 MB | 0.88 s, 125.5 MB → 0.96 s, 143.3 MB | 1.16 s → 1.30 s |
| mongodb-atlas/atlas | 6.8 | 488 | 1.5 MB | 0.2 MB + 13 files, 1.5 MB | 2.7 MB | 0.79 s, 112.4 MB → 0.86 s, 113.8 MB | 1.04 s → 1.18 s |
| github/webhooks | 6.3 | 0 | no operations: skipped, as Distilled does | | | | |
| sentry/sentry | 6.3 | 283 | 2.1 MB | 0.3 MB + 17 files, 2.1 MB | 2.5 MB | 0.88 s, 126.3 MB → 1.00 s, 132.8 MB | 1.20 s → 1.34 s |

`require` of the client, before → after (lua/luajit: time, Lua heap; Rex: time, process max RSS):

| Model | lua 5.5 | luajit | Rex (gopher-lua) |
| --- | --- | --- | --- |
| infisical/infisical | 125.2 ms, 30.6 MB → 19.5 ms, 5.2 MB | refused → 14.0 ms, 5.3 MB | 10655.7 ms, 276.9 MB → **74.2 ms**, 65.6 MB |
| cloudflare/zero_trust | 68.7 ms, 15.1 MB → 9.6 ms, 2.9 MB | refused → 6.7 ms, 2.9 MB | 4125.0 ms, 164.9 MB → **23.5 ms**, 52.3 MB |
| stripe/stripe | 38.9 ms, 9.6 MB → 5.5 ms, 1.9 MB | 34.7 ms, 10.8 MB → 4.0 ms, 1.9 MB | 2564.5 ms, 123.5 MB → **20.0 ms**, 52.8 MB |
| datadog/v2 | 35.1 ms, 9.8 MB → 9.3 ms, 2.6 MB | 32.5 ms, 10.9 MB → 7.2 ms, 2.7 MB | 2866.0 ms, 127.3 MB → **50.0 ms**, 57.5 MB |
| azure/network | 21.6 ms, 5.7 MB → 5.5 ms, 1.6 MB | 18.1 ms, 6.3 MB → 3.6 ms, 1.6 MB | 711.2 ms, 95.0 MB → **20.6 ms**, 52.4 MB |
| elasticsearch/elasticsearch | 21.1 ms, 6.1 MB → 4.1 ms, 1.4 MB | 19.7 ms, 6.8 MB → 2.9 ms, 1.4 MB | 1048.8 ms, 97.2 MB → **23.2 ms**, 52.1 MB |
| aws/ec2 | 14.5 ms, 4.8 MB → 4.5 ms, 1.6 MB | 12.2 ms, 5.3 MB → 3.5 ms, 1.6 MB | 687.4 ms, 76.1 MB → **25.7 ms**, 52.2 MB |
| cloudflare/radar | 17.5 ms, 4.8 MB → 2.5 ms, 1.1 MB | 15.1 ms, 5.3 MB → 2.0 ms, 1.1 MB | 482.1 ms, 88.1 MB → **8.0 ms**, 47.2 MB |
| mongodb-atlas/atlas | 13.6 ms, 3.7 MB → 3.0 ms, 1.1 MB | 11.5 ms, 4.0 MB → 2.6 ms, 1.1 MB | 465.3 ms, 76.5 MB → **12.5 ms**, 49.9 MB |
| sentry/sentry | 17.1 ms, 4.6 MB → 2.6 ms, 1.0 MB | 15.0 ms, 5.1 MB → 2.1 ms, 1.0 MB | 391.2 ms, 83.1 MB → **7.9 ms**, 47.6 MB |

After, the first call of the first operation by name (minimal input, scripted 200 response):

| Model | shape files loaded | lua 5.5 (time, heap after) | luajit | Rex (time, process max RSS) |
| --- | --- | --- | --- | --- |
| infisical/infisical | 1/113 | 14.0 ms, 7.7 MB | 11.5 ms, 7.9 MB | 55.8 ms, 83.2 MB RSS |
| cloudflare/zero_trust | 1/71 | 10.6 ms, 4.5 MB | 9.2 ms, 4.5 MB | 42.7 ms, 65.0 MB RSS |
| stripe/stripe | 5/37 | 11.8 ms, 4.0 MB | 9.7 ms, 4.2 MB | 62.2 ms, 66.1 MB RSS |
| datadog/v2 | 1/27 | 4.7 ms, 3.4 MB | 3.9 ms, 3.7 MB | 20.4 ms, 66.5 MB RSS |
| azure/network | 1/18 | 3.2 ms, 2.2 MB | 2.5 ms, 2.2 MB | 13.3 ms, 57.6 MB RSS |
| elasticsearch/elasticsearch | 1/17 | 3.0 ms, 2.1 MB | 2.3 ms, 2.1 MB | 13.7 ms, 57.1 MB RSS |
| aws/ec2 | 1/11 | 2.5 ms, 2.2 MB | 1.9 ms, 2.2 MB | 11.4 ms, 56.0 MB RSS |
| cloudflare/radar | 1/17 | 3.5 ms, 1.7 MB | 2.9 ms, 1.8 MB | 15.7 ms, 56.4 MB RSS |
| mongodb-atlas/atlas | 1/11 | 2.4 ms, 1.6 MB | 1.9 ms, 1.6 MB | 11.0 ms, 53.9 MB RSS |
| sentry/sentry | 1/16 | 3.0 ms, 1.6 MB | 2.5 ms, 1.7 MB | 15.1 ms, 54.5 MB RSS |

Synthetic (`syn:<ops>:8`, big_synth.lua), Rex `require` before → after: 1,000 ops
312 ms → 33 ms; 3,000 ops 2.3 s → 97 ms (luajit refused before); 10,000 ops 28.3 s →
333 ms (eager ops are the remaining cost: ~33 ms per 1,000 in Rex). Generation is ~10%
slower (emit.scan) and needs ~5-15% more memory; infisical takes 815 MB in luajit.
