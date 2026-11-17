# Task 22: Tencent Cloud — done

## What was built

- `lua/distilled/tencentcloud/signer.lua`: TC3-HMAC-SHA256 (port of `signer.ts`), UTC
  date without `os.date`, signed headers deduplicated and sorted.
- `lua/distilled/tencentcloud/errors.lua`: the 27 common-code classes of `errors.ts`
  (categories, retryable/throttling), `envelope_error` (first segment, ServiceUnavailable
  -> core class, else UnknownTencentCloudError), unknown/parse classes. `request_id` field.
- `lua/distilled/protocol/tencentcloud.lua`: API 3.0 protocol (port of `protocol.ts`,
  `credentials.ts`, `region.ts`): signed POST to `https://<service>.<root_domain>/`,
  X-TC-* headers, region order (input > client option > TENCENTCLOUD_REGION > none),
  env credentials (TENCENTCLOUD_SECRET_ID / _SECRET_KEY / _SESSION_TOKEN / _REGION),
  `root_domain`, `endpoint` (ours), the `Response` envelope at any status, status-map
  fallbacks, parse error, validation modes, redaction, spans, retry metadata.
- `lua/distilled/gen/rpc.lua` + small hooks in `gen/provider.lua`, `gen/ops.lua`,
  `gen/writer.lua`, `gen/types.lua`, `gen/traits.lua`: provider spec key `rpc` for
  models without `smithy.api#http` (one binding, `op.rpc` from the operation trait,
  checked at generation; init.lua / README / types options from the protocol module).
- `providers/tencentcloud.lua`; `clients/tencentcloud/` (263 models + index,
  regenerated after merging task 18's chunked emission).
- Pagination: none, as Distilled (0 `makePaginated` in its 264 service files).
- Verification: `verify/lib/tencentcloud_ref.mjs` + `verify/dl tencentcloud-ref` (Distilled
  in Node -> `spec/golden/tencentcloud/ref.json`), `verify/lib/gen_check.lua` signs every
  rpc op through the client's protocol, specs `spec/tencentcloud_{conform,protocol,gen}_spec.lua`,
  `verify/features/tencentcloud.md`, STATUS section 22.

## Commands run (final, after `git merge main` with tasks 13, 16, 18, 24)

```
$ verify/dl models sync tencentcloud
ok   tencentcloud: 263 models (263 new, 0 changed, 0 removed)
$ verify/dl doctor
doctor: ok
$ verify/dl test
  lua: ok 1595 passed, 5 pending [Lua 5.5]
  luajit: ok 1595 passed, 5 pending [luajit]
  rex: ok 1582 passed, 10 pending [rex]
$ verify/dl test --http tencentcloud
  lua: ok 147 passed [Lua 5.5]
  luajit: ok 147 passed [luajit]
  rex: ok 147 passed [rex]
$ verify/dl test --http          (before the last merge)
  lua: ok 1498 passed / luajit: ok 1498 passed / rex: ok 1466 passed, 4 pending
$ verify/dl gen-diff tencentcloud
ok   generate: package tencentcloud: 263 ok, 0 failed, 0 skipped; 15381 operations -> tencentcloud
ok   generate: lua and luajit write identical files
ok   diff: clients/tencentcloud matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 263 services, 54614 shapes, 76257 refs resolved, 15381/15381 ops built, ...; client loads
ok gen-check luajit: 263 services, ... 15381/15381 ops built, ...; client loads
ok gen-check rex: 263 services, ... 15381/15381 ops built, ...; service load 1949.3 ms; client loads
gen-diff tencentcloud: ok
$ verify/dl gen-diff neon            -> gen-diff neon: ok
$ verify/dl conform neon --replay    -> conform: ok
$ verify/dl tencentcloud-ref         -> node: 16 signer vectors, 17 requests, 85 responses
                                        (rerun: ref.json unchanged, deterministic)
$ verify/dl parity                   -> | tencentcloud | 15381 | 15381 | 263/263 | 0 | yes |
                                        (parity.md not committed: shared file)
```

Evidence: conformance spec in all three runtimes compares our signer, every request
(URL, Authorization, X-TC-*, Content-Type, body bytes) and every response outcome with
Distilled's; 0 mismatches. Distilled's signer vectors are cross-checked in Node against
an independent node:crypto implementation, and include the documented example
(`a7b85514...`). Error, empty and retry paths: all 27 common codes, ServiceUnavailable,
product codes, `hasOwnProperty`/`toString` codes, missing Code/Message/RequestId,
non-string codes, envelope on HTTP 400/500, 302/404/418/429/502/503/599 without
envelope, empty/non-JSON/array/non-object bodies, strict/additional validation,
RequestLimitExceeded and InternalError retried then success, AuthFailure not retried,
503 with Retry-After, TransportError, missing credentials (ConfigError, nothing sent),
and one signed call over real HTTP against `dl serve` (lua, luajit, rex host).

Load: csip (largest, 758 ops) `require` 8 ms lua/luajit, 57 ms Rex with task 18's
emission (0.4 s before it).

## Intended differences

Listed in `verify/features/tencentcloud.md`: sorted body keys (signature covers our
bytes; the reference uses sorted inputs so bytes match), `status` on every error,
ServiceUnavailable keeps `code`/`request_id`, descriptive parse error message, the
extra `endpoint` option.

## Skipped / not verified

- No live Tencent Cloud call (no credentials; the rules forbid network in tests).
- Profile/file credentials: Distilled has none (env and explicit only), so none here.
- `verify/features/parity.md` and `verify/features/README.md` not edited (shared files;
  noted in STATUS for the orchestrator).

## Open problems

- `verify/dl gen-diff hetzner` fails on this branch and identically on main:
  `clients/hetzner` (unchanged by me, equal to main) predates task 13's writer changes
  (error-envelope comment and code). Not caused by the rpc hooks (they only act with
  `spec.rpc`); the owner of hetzner/task 13 should regenerate it.
- One Rex failure in the very first `dl test --http tencentcloud` run whose output was
  lost; 14 reruns (rex alone and all runtimes, with and without `--http`) passed. Possibly
  a dl serve timing flake in the HTTP case; not reproduced.
- Contract additions for `docs/interfaces.md` (op `rpc` field, spec key `rpc`, protocol
  module convention) are listed in STATUS section 22.
