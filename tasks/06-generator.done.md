# Task 06: the generator (done)

## What was built

| File | What |
| --- | --- |
| `lua/distilled/gen/init.lua` | `gen.plan` / `gen.generate{ model, provider, ops, telemetry }` -> files, `gen.write`; the seven steps of Distilled's `generateService`, every check that can fail |
| `lua/distilled/gen/model.lua` | load and index the Smithy JSON, `ensureNamedIo`, `inheritServiceErrors`, `booleanStringEnums`, reachability (explicit stack), validation (dangling targets, prelude names, local-name clashes, error traits, mixins/resources), the trait audit, FNV-1a model hash |
| `lua/distilled/gen/json_ordered.lua` | JSON decoder that keeps object key order (Smithy member order matters; `distilled.json` cannot carry it) |
| `lua/distilled/gen/traits.lua` | every known trait id: handled (where), ignored (why) or `fail` (why); the guarded namespaces |
| `lua/distilled/gen/naming.lua` | snake_case with acronyms, digits and a word list; collisions, keywords, client methods; nearest-name suggestions |
| `lua/distilled/gen/shapes.lua` | shapes -> schema nodes: binding cascade, wire names, required/default/items rule, nullable, sensitive, string_encoded, greedy, open, enum/intEnum, list, map, union + discriminator |
| `lua/distilled/gen/errors.lua` | `errorCategories` port, matcher validation, regex compilation, fields |
| `lua/distilled/gen/ops.lua` | http trait, URI labels, raw outputs, pagination validation, retry policy, telemetry compression, op descriptors |
| `lua/distilled/gen/types.lua` | LuaLS `---@meta` definitions |
| `lua/distilled/gen/emit.lua` | deterministic, stylua-clean Lua source writer |
| `lua/distilled/gen/writer.lua` | `service.lua`, `init.lua`, `README.md` |
| `lua/distilled/gen/provider.lua` | provider spec validation (unknown keys rejected) |
| `bin/distilled-lua` | `generate --model --provider --out [--ops] [--no-telemetry] [--quiet]`, `vendor --out` |
| `providers/neon.lua` | Neon: base URL (+ `base_url` option, `NEON_API_BASE_URL`), bearer `api_key` (`NEON_API_KEY`), `UnknownNeonError`, `NeonParseError`, multipart acknowledged |
| `clients/neon/` | the generated client: `init.lua`, `service.lua` (250 KB), `types.lua` (356 KB), `README.md` |
| `verify/dl` | `gen-diff <provider>` (replaces the stub; help text) |
| `verify/lib/gen_check.lua`, `gen_input.lua`, `gen_fixture.lua`, `gen_load_bench.lua` | gen-diff's per-runtime check, input synthesis, the spec fixture model, load bench |
| `verify/features/generator.md` | feature map entry |
| specs | `gen_naming`, `gen_emit`, `gen_model`, `gen_provider`, `gen_shapes`, `gen_errors`, `gen_ops`, `gen_output`, `gen_neon`, `neon_client` (153 + 28 tests) |

Extra files under `lua/distilled/gen/` beyond the brief's list (`json_ordered.lua`,
`traits.lua`, `writer.lua`) are inside the generator directory I own; `gen_fixture.lua`
and `gen_load_bench.lua` are `verify/lib/gen_*`.

## Commands run (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) ...
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
...
== summary
  lua: ok 978 passed, 3 pending [Lua 5.5]
  luajit: ok 986 passed, 3 pending [luajit]
  rex: ok 986 passed, 6 pending [rex]
(counts move while other tasks add specs; a rerun a minute later gave lua 988 passed)

$ verify/dl gen-diff neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
note op create_project_branch_function_deployment: multipart refused by request.build (acknowledged)
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 177/178 ops built, 1 acknowledged unsupported; service load 2.2 ms; client loads
note op create_project_branch_function_deployment: multipart refused by request.build (acknowledged)
ok gen-check luajit: 649 shapes, 835 refs resolved, 177/178 ops built, 1 acknowledged unsupported; service load 2.0 ms; client loads
note op create_project_branch_function_deployment: multipart refused by request.build (acknowledged)
ok gen-check rex: 649 shapes, 835 refs resolved, 177/178 ops built, 1 acknowledged unsupported; service load 23.7 ms; client loads
gen-diff neon: ok

$ for rt in lua luajit; do $rt spec/run.lua gen_; $rt spec/run.lua neon_client; done
ok 153 passed [Lua 5.5]     ok 28 passed [Lua 5.5]      (neon_ filter)
ok 153 passed [luajit]      ok 28 passed [luajit]
$ rex do spec/run.lua filter=gen_ ; rex do spec/run.lua filter=neon_
ok 149 passed, 1 pending [rex]   ok 28 passed [rex]

$ stylua --check lua/distilled/gen spec/gen_*_spec.lua spec/neon_client_spec.lua \
    verify/lib/gen_*.lua providers bin/distilled-lua
(clean)

$ lua bin/distilled-lua generate --model models/neon.json --provider providers/neon.lua --out clients/neon
wrote clients/neon: 178 operations, 649 shapes, 5 errors, 4 files (632282 bytes)
(0.18 s under lua, 0.12 s under luajit; about 1 s inside Rex, which it does not need)
```

The one Rex pending is the CLI describe in `gen_output_spec` (`bin/distilled-lua` needs
`io.popen`/`os.execute`, which Rex lacks). The other pendings are other tasks'.

## 178 operations

All 178 are emitted. 177 build a request from a synthesized minimal input in all three
runtimes. `CreateProjectBranchFunctionDeployment` is `multipart`, which `request.build`
refuses with SdkError; the generator fails on a multipart operation unless the provider
spec lists `"multipart"` in `allow_unsupported` (Neon's does), and gen-check requires that
exact SdkError for it. This is the one place the brief's "all 178 build" is not met; the
fix is multipart support in `request.lua` (proposed in STATUS.md).

## Load time and memory (full Neon client, `verify/lib/gen_load_bench.lua`)

| Runtime | runtime modules (client, rest, ...) | `neon.service` (generated data) | `neon` class |
| --- | --- | --- | --- |
| lua 5.5 | 3.4 ms, 338 KB | 2.1 ms, 597 KB | 0.2 ms, 33 KB |
| luajit | 3.3 ms, 297 KB | 1.9 ms, 661 KB | 0.3 ms, 39 KB |
| rex (gopher-lua) | 9.5 ms | 23 ms | 0.4 ms |

Rex reports no memory (`collectgarbage("count")` is nil) and its `os.clock` is wall time.
A 3-operation `--ops list_projects,get_project,create_project` client: service 0.3 ms /
78 KB (lua), 1.2 ms in Rex. Loading is cheap, so shape construction is not lazy: plain
table literals, one registry entry per shape.

## Traits (every id `jq` lists in models/neon.json, plus the rest of gen/traits.lua)

Handled (in Neon): `smithy.api#http` (method, uri, code, contentType; bodyMediaType too),
`smithy.api#httpLabel`, `httpQuery`, `httpPayload`, `httpError`, `smithy.api#required`,
`smithy.api#sensitive`, `smithy.api#enumValue`, `smithy.api#error`,
`smithy.api#paginated`, `smithy.api#documentation` (types and README),
`com.distilled.openapi#nullable`, `errorMatchers`, `rawResponse`, `contentType`,
`distilled.errors#bodies` (types: documented body types of an error class),
`com.distilled.telemetry#service`, `#operation`, `#attributes`.

Handled (not in Neon, covered by the fixture specs): `smithy.api#httpHeader`,
`httpResponseCode` (bind = status), `jsonName`, `default`, `retryable`,
`com.distilled.openapi#additionalProperties`, `distilled.errors#categories`,
`distilled.retry#policy`, `distilled.protocols#stringEncoded`.

Ignored on purpose: `smithy.api#input`, `smithy.api#output` (the operation says so),
`smithy.api#title` (the provider spec names the client); plus, not in Neon:
`suppress`, `deprecated`, `tags`, `examples`, `externalDocumentation`, `readonly`,
`idempotent`, `idempotencyToken`, the constraint traits, `timestampFormat`, `mediaType`,
and the `http*Auth` traits (auth comes from the provider spec).

Fail with a reason: `httpQueryParams`, `httpPrefixHeaders`, `httpChecksumRequired`,
`com.distilled.openapi#streamWhen`, `com.distilled.grpc#serverStreaming`. Any other id
under `smithy.api#http`, `com.distilled.openapi#`, `com.distilled.telemetry#`,
`com.distilled.grpc#` or `distilled.` fails; others warn (`gen_neon_spec` asserts Neon
has 22 ids, all handled or ignored, and no warnings).

## Evidence for the requirements

- **Naming** (`gen_naming_spec`): 20 written cases (GetOAuthClient, ListIPAllowlist,
  GetV2Thing, JWKS, DataAPI, SDKKeys, ...), collisions including `_pages`/`_items`
  siblings, keywords (with an override fix), client method names.
- **Shapes** (`gen_shapes_spec`): every binding, wire names, every prelude scalar,
  required/default/items rule, nullable, sensitive on member and shape, open, enum,
  intEnum, list, map, union discriminator, recursion through `ref`, registry pruning,
  snake_case policy and its collision fallback, refusals.
- **Errors** (`gen_errors_spec`): every status of `errorCategories`, retryable /
  throttling / declared categories, matchers through `errors.match`, a regex that does
  not compile fails generation, unknown matcher keys, JSON pointer keys, null matchers.
- **Operations** (`gen_ops_spec`): pagination (missing field per mode, token/items/page
  size not members, fallback, unknown mode/key), retry policy merge and validation,
  telemetry hoisting and per-op differences, `--no-telemetry`, `--ops` subset and
  suggestions, multipart rule, http trait refusals, type-name collisions.
- **Output** (`gen_output_spec`, `gen_neon_spec`): byte-identical regeneration (and of the
  real Neon client in all three runtimes), hash header and no timestamps, `init.lua`
  hands `Client.define` / `rest.new` the right arguments (bearer, header auth, envelope,
  status map, classify module, protocol escape hatch), stylua-clean for every provider
  variant, types and README content, CLI exit codes, `vendor`.
- **Neon client** (`neon_client_spec`, over `testing.host` / `testing.transport`):
  get_project success and NotFound (and unknown status, missing label), label escaping,
  list_projects_items across two pages with the cursor, pages, a failing page in a `for`
  loop, sensitive `key` as a secret, bearer header, request bodies (create_api_key,
  create_project, update_project_branch), rawResponse outputs (list_api_keys JSON array,
  bucket object bytes), the multipart SdkError, base URL option and env override, missing
  key ConfigError, no key in errors, operation span names and attributes, `err.trace_id`.
  Requests compared by hand with `neon.ts`: getProject, listProjects (all members
  T.Query, cursor trait), createApiKey (key_name body, T.SensitiveValue on `key`),
  createProject, updateProjectBranch (two T.Label, branch body), listApiKeys
  (`ListApiKeysResponse = ListApiKeysResponseBodyList`), getProjectBranchBucketObject
  (`Uint8Array`).

## Skipped, and why

- **lua-language-server checking of `types.lua`**: not installed. The annotations were
  written against https://luals.github.io/wiki/annotations/ and are checked by reading
  and by the content assertions in `gen_output_spec`; `types.lua` compiles as Lua.
- **Multipart** for `CreateProjectBranchFunctionDeployment`: see above.
- **CLI under Rex**: not needed (the brief), pending in that runtime. The generator
  library itself does run under gopher-lua (`gen_neon_spec` regenerates Neon there).
- **Distilled's bundle-size machinery** (dedupe, privatize, chunk, datafy, latin1): not
  needed; the load numbers above.
- **Closed enum literals** that Neon's `shapeOverride` emits for a few names (`Trigger*`
  and the email server types): Lua enums are open unless validation is strict, and types
  list the values either way.

## Deliberate differences from Distilled

- A pagination trait whose token or items is not a member fails generation (Distilled
  quietly degrades the operation to a plain one).
- Operation names are snake_case (decision 2); collisions are checked over the whole
  model, so `--ops` cannot hide one.
- Shapes are emitted sorted by name, not in dependency order (refs make order
  irrelevant); structurally identical shapes are not merged (no bundle to shrink).
- Error shapes with no members get no `fields` (Distilled's default `code`/`message`
  are instance fields of every error here).

## Open problems (also in STATUS.md)

- Multipart bodies in `request.lua` (not my file).
- `dl doctor` could compare `clients/*/` headers with the model hash (not my command).
