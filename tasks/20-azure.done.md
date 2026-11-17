# Task 20: Azure, done

## What was built

- **Generator support** (`lua/distilled/gen/azure.lua`, hooks in `gen/ops.lua`,
  `gen/init.lua`, `gen/traits.lua`): `op.api_version` from the http trait's
  `apiVersion` (else `com.distilled.openapi#apiVersion`; the http trait wins when they
  differ, Distilled's fold; cognitiveservices has such an op); an api-version under a
  non-Azure protocol fails generation; generate.ts's `markScopeLabelsGreedy` (a leading
  `/{scope}` label becomes `{scope+}`); ARM ids that differ only in case (workloads, 19
  pairs, one per api-version) get distinct names, the older api-version as a suffix.
  `gen/writer.lua` passes a task-13 spec's runtime data to a `protocol` module.
  `naming.rtrim` strips trailing Unicode whitespace in docs (U+202F broke stylua).
- **Protocol** `lua/distilled/protocol/azure.lua` (port of `protocol.ts` and
  `credentials.ts`, on `rest.new`): bearer auth, `Accept: application/json`,
  `api_base_url`, options resolved every request, `{subscriptionId}` injection (explicit
  wins; missing everywhere is a ConfigError), `?api-version=` appended, the ARM failure
  order (message matchers, code map, `details[].code`, status map with Retry-After,
  unmapped 5xx, `UnknownAzureError` with `target`).
- **Errors** `lua/distilled/azure/errors.lua` + `errors_data.lua` (180 classes, 92
  codes, 125 matchers), written from Distilled's loaded `errors.ts` by
  `verify/lib/azure_errors_port.mjs` (`verify/dl azure-errors`).
- **Credentials**: Distilled's token only, plus (additions) Entra ID client credentials
  through the provider spec's `oauth` (token reused until 5 minutes before expiry) and
  `lua/distilled/azure/credentials.lua` (`cli()` through host.exec, `managed_identity()`
  for IMDS / App Service).
- **Provider spec** `providers/azure.lua`; **clients** `clients/azure/` (223 models,
  13,869 operations, 78 MB, split by task 18's emitter where needed).
- **Conformance**: `verify/lib/azure_cases.lua` (1,170 request cases sampled from every
  model) and `verify/lib/azure_ref.mjs` (Distilled's answers) write
  `spec/fixtures/azure/cases.json` and `spec/golden/azure/ref.json`
  (`verify/dl azure-ref`); `spec/azure_conform_spec.lua` compares in all three runtimes.
- **Specs**: `spec/azure_conform_spec.lua`, `spec/azure_protocol_spec.lua` (port of
  `protocol.test.ts`, `errors.test.ts`, `response-headers.test.ts`, plus env per
  request, subscription rules, retries, refresh, client credentials, one HTTP case
  against `dl serve`), `spec/azure_credentials_spec.lua`, `spec/azure_gen_spec.lua`.
  One case each changed in `spec/gen_ops_spec.lua` (apiVersion is no longer an unknown
  http key) and `spec/provider_spec.lua` (azure in the provider list).
- **Docs**: `verify/features/azure.md`, STATUS section 20, `verify/features/parity.md`
  regenerated.

## Commands run (after the last `git merge origin/main`)

```text
$ verify/dl doctor
... doctor: ok

$ verify/dl test
== summary
  lua: ok 1933 passed, 6 pending [Lua 5.5]
  luajit: ok 1933 passed, 6 pending [luajit]
  rex: ok 1920 passed, 11 pending [rex]

$ verify/dl test --http            (before the last merge; azure_protocol re-run after it)
  lua: ok 1973 passed [Lua 5.5]
  luajit: ok 1973 passed [luajit]
  rex: ok 1940 passed, 5 pending [rex]
$ verify/dl test --http azure_protocol
  lua: ok 47 passed [Lua 5.5]
  luajit: ok 47 passed [luajit]
  rex: ok 47 passed [rex]

$ verify/dl test azure_
  lua: ok 334 passed, 1 pending [Lua 5.5]     (the pending one is the HTTP case)
  luajit: ok 334 passed, 1 pending [luajit]
  rex: ok 334 passed, 1 pending [rex]

$ verify/dl gen-diff azure
ok   generate: package azure: 223 ok, 0 failed, 0 skipped; 13869 operations -> azure
ok   generate: lua and luajit write identical files
ok   diff: clients/azure matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 223 services, 82376 shapes, 113654 refs resolved, 13869/13869 ops built, 0 acknowledged unsupported; service load 290.1 ms; client loads
ok gen-check luajit: ... 13869/13869 ops built ...; service load 315.6 ms; client loads
ok gen-check rex: ... 13869/13869 ops built ...; service load 1490.7 ms; client loads
gen-diff azure: ok

$ verify/dl azure-ref && verify/dl azure-errors && git status --short
wrote .../cases.json: 1170 cases
wrote .../ref.json: 1170 requests (0 operations missing in Distilled), 39 responses, 182 classes
wrote .../errors_data.lua: 180 classes, 92 codes, 125 matchers
(no changes: deterministic)

$ verify/dl parity
| azure | 13887 | 13869 | 223/223 | 18 | yes |
```

Operation names: every one of the 13,869 TS exports of the 223 models has a Lua
operation of that model name (a LC_ALL=C sorted diff of both lists is empty). The 18
the parity table counts as missing are in `planetarycomputer.ts` (6) and `portal.ts`
(12), TS service files with no model in `.generated-specs`.

Conformance (`spec/azure_conform_spec.lua`, all three runtimes): 1,170 requests equal
in method, URL (byte for byte: `$filter` -> `%24filter`, `'` -> `%27`, greedy labels,
injected subscription id, api-version placement), every header Distilled sends but
content-length, and body; 39 responses equal in value or error (tag, categories,
retryable, throttling, code, message, target, retry_after, body). Mutation check: with
the api-version append removed, 223 of 266 cases fail; with another Accept, all 1,170
requests report the header.

## Skipped, and why

- **Pagination via nextLink**: not ported because Distilled has none (generate.ts: "no
  pagination profiles, v0 emitted zero paginated ops"; list operations return
  `{ value, nextLink }`). Following a nextLink would also need a host check before the
  token is sent to the link's origin. Possible follow-up, not parity.
- **LRO polling**: Distilled has none (the 202's `Azure-AsyncOperation` / `Location` /
  `Retry-After` headers are in the output, tested).
- **Live Azure calls**: none (no credentials, and the proof bar forbids them); the HTTP
  path is proven against `dl serve`.
- The Entra ID client-credentials flow, the CLI and managed-identity sources are tested
  against scripted transports / exec only, not against Entra ID or a real VM.

## Open problems (also in STATUS section 20)

- `operation.lua` refreshes credentials only on tag `Unauthorized`; Azure's typed 401s
  (`InvalidAuthenticationToken`, ...) do not refresh. `ExpiredAuthenticationToken` does.
- Distilled sets no `retryAfter` on code-mapped classes, so a mapped 429 is retried on
  backoff, not after its Retry-After. Kept for parity.
- `t.pending` inside a running test passes silently (tencentcloud's HTTP case).
