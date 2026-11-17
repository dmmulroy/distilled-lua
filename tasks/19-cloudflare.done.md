# Task 19: Cloudflare: done

## What was built

- **`lua/distilled/protocol/cloudflare.lua`** ports `protocol.ts`, `credentials.ts`,
  `errors.ts` and `jurisdiction.ts`. It is `rest.new` with its own encode and decode.
  - **Envelope** `{ success, errors, messages, result, result_info }`:
    - `success: false` under any status is a failure.
    - Bare-payload outputs are supported.
    - Binary bodies project typed headers. Non-JSON bodies are handled.
    - K2's single `error` object is read.
    - Strict mode rejects unmodelled envelope keys.
    - The key dictionary's fallback wire names are read.
  - **Errors**, in protocol.ts's order:
    1. The operation's typed errors (the model's per-code matchers). The code is 0 when
       the envelope has none.
    2. The global codes: 971, 6003/9103/9106/9109, 10000, 10001, 7003 and 1000.
    3. Throttling.
    4. Status classes.
    5. `UnknownCloudflareError`.

    Unparseable bodies raise `CloudflareParseError`. Transient authentication blips are
    retryable on every path.
  - **Auth**:
    - `api_token` is sent as a Bearer token.
    - `api_key` plus `email` are sent as `x-auth-key` and `x-auth-email`. One without the
      other is a ConfigError.
    - The defaults come from `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_API_KEY` and
      `CLOUDFLARE_EMAIL`.
    - The base URL comes from the `base_url` option or `CLOUDFLARE_API_BASE_URL`.
    - A member-supplied `Authorization` header gets the Bearer prefix.
  - **Requests**:
    - Unknown input keys are sent snake_cased.
    - Deep query objects are sent as `a.b=`.
    - Multipart bodies come from `formDataFile` members.
    - Per-operation hosts are supported (pipelines).
    - The R2 jurisdiction is sent in the `cf-r2-jurisdiction` header, from the client
      option or the call.
  - **Validation** treats every union as `unknown`. This is Distilled's unionStyle
    `opaque-cases`, done through a lazy registry view.
- **`lua/distilled/gen/cloudflare.lua`** ports the SdkSpec of `scripts/generate.ts`.
  Small hooks in `gen/init.lua`, `ops.lua`, `shapes.lua`, `traits.lua` and `writer.lua`
  call it.
  - The `com.cloudflare.protocols#*` traits become generic vocabulary.
  - `optionalsNullable` is applied, and paginated outputs get a `result_info` member.
  - Pagination paths are translated from TS names to wire names.
  - `validatePaginated`: an unusable trait is dropped with a warning.
  - opAliases become second methods on the target operation.
  - It writes the client's `init.lua` and the README option rows.
- **`lua/distilled/paginate.lua`**: `trait.strategy` picks `strategies["cloudflare.page"]`
  (pagination.ts). Other modes fall back to the core ones. Neon's modes are unchanged.
- **`providers/cloudflare.lua`** and **`clients/cloudflare/`** (generated, committed):
  130 models, 3,128 operations plus 25 alias methods. The large services use task 18's
  split layout.
- **Specs**:
  - `spec/cloudflare_protocol_spec.lua` ports protocol.test.ts, plus aliases and helpers.
  - `spec/cloudflare_pagination_spec.lua` ports pagination.test.ts, plus cursor and stop
    cases.
  - `spec/cloudflare_conform_spec.lua` replays the conformance cases and checks that a
    changed reference is reported.
- **Conformance against Distilled's TS SDK** (`verify/conform/cloudflare/`):
  - `cases.lua` writes the cases: up to 5 operations per model, with request,
    envelope-success, nulls-under-strict, typed-error, unknown-code and
    rotating-failure cases, plus pagination flows.
  - `ts.mjs` answers them with Distilled, imported by path, over a scripted HttpClient.
  - `compare.lua`, `intended.lua` and `run.lua` compare the two sides, using `lib.lua`.
  - The saved `cases.jsonl` and `ref.jsonl` are committed.
- **`verify/dl models sync`** also copies `manual-specs/*.json` when generate.ts reads
  them. That is how K2 arrives.
- `verify/features/cloudflare.md`, and the STATUS.md section "19 cloudflare".

## Commands run (final state, after `git merge origin/main` at 535c691, task 22)

```text
$ verify/dl doctor
... ok manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
  lua: ok 1677 passed, 5 pending [Lua 5.5]
  luajit: ok 1677 passed, 5 pending [luajit]
  rex: ok 1664 passed, 10 pending [rex]

$ verify/dl test cloudflare
  lua: ok 82 passed [Lua 5.5]
  luajit: ok 82 passed [luajit]
  rex: ok 82 passed [rex]

$ verify/dl gen-diff cloudflare
ok   generate: package cloudflare: 130 ok, 0 failed, 1 skipped; 3153 operations -> cloudflare
ok   generate: lua and luajit write identical files
ok   diff: clients/cloudflare matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 130 services, 64288 shapes, 65533 refs resolved, 3153/3153 ops built, 0 acknowledged unsupported; service load 91.7 ms; client loads
ok gen-check luajit: 130 services, 64288 shapes, 65533 refs resolved, 3153/3153 ops built, 0 acknowledged unsupported; service load 90.4 ms; client loads
ok gen-check rex: 130 services, 64288 shapes, 65533 refs resolved, 3153/3153 ops built, 0 acknowledged unsupported; service load 927.9 ms; client loads
gen-diff cloudflare: ok

$ lua verify/conform/cloudflare/cases.lua .
cloudflare conform: 3090 cases over 536 operations of 130 models -> ./verify/conform/cloudflare/cases.jsonl
$ node --conditions=bun --experimental-transform-types --no-warnings verify/conform/cloudflare/ts.mjs
node: 3090 cloudflare cases answered by Distilled (0 operations not found)
$ lua verify/conform/cloudflare/run.lua .
cloudflare conform: 3090 cases, 3090 compared (requests 540, responses 2415, flows 135), 0 mismatches
  intended (1): CloudflareParseError message: Distilled's class has no message field (body and cause only); Lua's names the operation and the mismatch. Compared by the cause's path and expectation instead

$ verify/dl gen-diff neon
gen-diff neon: ok
```

The conformance outcomes cover 1,206 successes and about 130 distinct error classes:

- typed, model-declared errors;
- Unauthorized, Forbidden, TooManyRequests, InvalidRoute;
- GatewayTimeout, BadGateway, Conflict, NotFound;
- `UnknownCloudflareError` and `CloudflareParseError`.

Of the 135 pagination flows, 64 are two pages and 71 are one.

The comparison's first run found 39 mismatches. Fixes on the Lua side:

- typed errors get code 0 when the envelope has none;
- unions are opaque under strict validation;
- Lua's own strict extra-key mismatch now carries `expected`.

Fixes in the harness:

- the key-dictionary and union-case projection that Distilled applies;
- multipart content-type, which fetch sets in TS;
- `result_info` was put inside `result` by the case synthesizer.

## Skipped, and why

- **No live Cloudflare calls.** No credentials, and the brief allows no network.
  Everything above uses the scripted transport or Distilled over a scripted HttpClient.
- **Conformance is a sample**: 536 of 3,153 operations. The other operations are
  covered by gen-check (each request built in all three runtimes), not by a TS
  comparison.
- **`layer-s3.ts`** is not ported. It provides S3 credentials and an endpoint for
  Distilled's separate S3 SDK: the token's id plus the SHA-256 of the token, and
  `<account_id>[.<jurisdiction>].r2.cloudflarestorage.com`. It belongs with an S3 client
  (task 25), not with protocol.ts.
- `types.lua` and the README list an alias as its own operation (documented "Alias of
  ..."). Distilled also re-exports the Request, Response and Error types under the alias
  names; we have no per-alias type names.

## Open problems

- **`verify/dl gen-diff hetzner` fails on main** as well as here, so it is not caused by
  this task. Task 13's writer change (840a51c, error envelope with pointer lists) did not
  regenerate `clients/hetzner`, and this branch does not touch `clients/hetzner`.
- Contract proposals are in STATUS.md:
  - core `errors.match` should default `code` to 0, as `matchTypedError` does;
  - `validate` could take an `opaque` union flag.
- One-line edit outside my list: `spec/provider_spec.lua` now lists `cloudflare`.

## Fix after the orchestrator's merge

`spec/cloudflare_conform_spec.lua` failed on main. The comparison read the key
dictionaries from `models/cloudflare/*.json`, which is synced locally and not committed,
so a fresh checkout has no such files. `cases.lua` now writes
`verify/conform/cloudflare/dictionaries.json` (committed), and `compare.lua` reads only
that. The regenerated `cases.jsonl` is byte-identical.

Checks, after `git merge main` (task 26):

- With `models/cloudflare` moved away, `verify/dl test` passed: lua 1681, luajit 1681 and
  rex 1668, 0 failed.
- In a fresh `git clone` of the branch, `verify/dl doctor` was ok and `verify/dl test
  cloudflare` passed 82/82 in all three runtimes.

## Merge with main (tasks 17 aws, 25 s3, 27)

The conflicts were in `gen/init.lua`, `ops.lua`, `shapes.lua` and `traits.lua`: the
Cloudflare and AWS hooks sat side by side. Both were kept. In `ops.pagination`, AWS's
items rule now comes before `local out = { mode = mode, strategy =
ctx.pagination_strategy }`.

Task 27 then changed the same line in `ops.pagination` (`mode` mapped through
`provider.pagination.modes`). The merged line keeps that mapping and Cloudflare's
`strategy` field. `paginate.lua` already dispatches on `strategy.mode` first and the
plain mode second.

Checks after the last merge (main e72b3520):

- `verify/dl doctor` was ok.
- `verify/dl test` passed: lua 1929, luajit 1929, rex 1916, 0 failed.
- `gen-diff cloudflare` and `gen-diff neon` were ok.
- s3 (an AWS model, checked by hand as task 25 does): generating with lua and with luajit
  gives files identical to `clients/s3`. gen-check passed under lua and luajit, with
  111/112 ops built and 1 acknowledged unsupported.
