# Task 28: signed REST (Coinbase, Polymarket) and the posthog/whop/coinflow gaps — done

## What was built

- **Coinbase** (`providers/coinbase.lua`, `providers/glue/coinbase.lua`, `clients/coinbase/`,
  178/178 operations). The CDP JWT follows `packages/coinbase/src/protocol.ts`: a fresh
  token per request, ES256 for an EC PEM secret and EdDSA for the base64 Ed25519
  seed || public key, header `{alg,kid,typ,nonce}` and claims
  `{sub,iss,aud,nbf,exp,uri}` in TypeScript key order. `nbf` comes from `host.epoch`
  and the 16-byte nonce from `host.random`. Failures go through `matchError` (49
  errorType classes, the standard types, the status map, 402, 5xx, unknown). A failure
  body with `isValid` or `success` is decoded as the value. The credential env names
  and error messages are the same as in credentials.ts.
- **Polymarket** (`providers/polymarket.lua`, `providers/glue/polymarket.lua`,
  `providers/glue/polymarket_clob.lua`, `clients/polymarket/`: 7 models, 223/223
  operations):
  - L2: the POLY_* HMAC headers on CLOB and Combos RFQ, as in protocol.ts and
    signing.ts.
  - Relayer and Perps headers.
  - Credential groups that must be complete (all or none).
  - `CLOB_API_URL` and a base URL per API.
  - 413 is mapped to PayloadTooLarge.
  - L1, which Distilled does not produce: `create_api_key` and `derive_api_key` get
    clob-client's `createL1Headers` when `l1_private_key` is set. That is an EIP-712
    ClobAuth signature on secp256k1 with low s and v = 27 + recid, plus an EIP-55
    address.
- **REST protocol hooks** (`lua/distilled/protocol/rest.lua`):
  - glue `sign(request, settings, { host, op, base_url })` runs after the request is
    built. Every retry attempt is signed again.
  - glue `accept_failure(info) -> true` decodes a >= 400 answer as the value.

  Both are registered in `gen/provider_ext.lua` `ext.HOOKS`. Provider-spec header names
  may now contain `_` and `.`.
- **Parity gaps** (requirement 3): all of them are spec drift. Each operation is listed
  in `tasks/notes/28-parity-gaps.md`, which `tasks/notes/28-gapcheck.mjs` produced. The
  Lua op count equals the current model's op count for all three packages (posthog
  2612, whop 437, coinflow 213).
  - The 10 posthog `loops` routes are in no current model, and the pinned mirror has no
    `/loops/` path.
  - The 14 whop routes (`/companies`, `/entries`, `/recommended_actions`, `/ad_reports`)
    are in neither of the two current documents.
  - Coinflow renamed subsidiaries to embedded accounts: 3 operations are only in TS and
    9 only in the model.

  No generator fix was needed, so posthog and whop were not regenerated. gen-diff still
  passes for both.
- **Verification tooling**:
  - `verify/lib/signed_rest_conform.mjs` runs Distilled's real operations over stubs.
  - `verify/lib/polymarket_l1_vectors.mjs` produces the clob-client 5.8.1 and ethers
    5.7.2 vectors.
  - `verify/dl signed-rest-vectors` regenerates the golden files.
  - The golden files are in `spec/golden/signed_rest/`.
  - The specs are `spec/signed_rest_spec.lua` (16 tests) and
    `spec/signed_rest_conform_spec.lua` (61 cases).
  - The feature doc is `verify/features/signed-rest.md`, which also lists the intended
    differences.

## Commands run (after the last `git merge main`)

```text
$ verify/dl doctor
... ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
  lua: ok 2510 passed, 22 pending [Lua 5.5]
  luajit: ok 2510 passed, 22 pending [luajit]
  rex: ok 2497 passed, 28 pending [rex]

$ verify/dl test signed_rest
  lua: ok 77 passed [Lua 5.5]
  luajit: ok 77 passed [luajit]
  rex: ok 77 passed [rex]

$ verify/dl gen-diff coinbase
ok   diff: clients/coinbase matches a fresh generation
ok gen-check Lua 5.5 / luajit / rex: 1153 shapes, 1569 refs resolved, 178/178 ops built
gen-diff coinbase: ok

$ verify/dl gen-diff polymarket
ok   diff: clients/polymarket matches a fresh generation
ok gen-check Lua 5.5 / luajit / rex: 7 services, 967 shapes, 1111 refs resolved, 223/223 ops built
gen-diff polymarket: ok

$ verify/dl gen-diff whop      -> 437/437 ops built (3 runtimes), gen-diff whop: ok
$ verify/dl gen-diff coinflow  -> 213/213 ops built (3 runtimes), gen-diff coinflow: ok
$ verify/dl gen-diff posthog   -> 2612/2612 ops built (3 runtimes), gen-diff posthog: ok

$ verify/dl signed-rest-vectors   (then git diff spec/golden/signed_rest: empty, deterministic)
wrote .../conform.lua: coinbase 12 requests, 29 responses; polymarket 14 requests, 6 responses
wrote .../l1.lua: 40 L1 header sets

$ verify/dl parity | grep -E "coinbase|polymarket|posthog|whop|coinflow"
coinbase     178  178    1/1    0  yes
coinflow     207  213  18/18   -6  yes
polymarket   223  223    7/7    0  yes
posthog     2622 2612 198/198  10  yes
whop         451  437  85/85   14  yes
```

The gen-diff runs for whop, coinflow and posthog came before the merge of main. The
coinbase and polymarket gen-diffs were re-run after it.

## What the evidence covers

- **Byte-exact against Node**:
  - Coinbase EdDSA JWTs (the whole token) and ES256 header and claims. The ES256
    signature is verified rather than compared, because node:crypto's k is random.
  - Polymarket L2 headers. Where the body bytes differ because Lua sorts JSON keys,
    Distilled's own `signL2` over the Lua body is in the golden file, and the Lua body
    and signature equal it.
  - 40 L1 header sets from Polymarket's official client.
  - The official L2 vector (`ZwAdJKvoYRlEKDkNMwd5BuwNNtg93kNaR_oU2HrfVvc=`).
- **Error, empty and retry paths**:
  - 29 Coinbase and 6 Polymarket failure outcomes, including empty bodies, HTML bodies,
    long bodies and bad envelopes.
  - Incomplete credential groups in all 7 Polymarket APIs.
  - Missing and broken Coinbase keys, with no secret in the error.
  - Bad L1 key, nonce and chain id.
  - 429 retries that re-sign: new nonce, nbf and timestamp.

## Skipped and why

- **No live calls.** There are no CDP or Polymarket credentials, and the rules forbid
  network calls in tests.
- **X-Wallet-Auth** (Coinbase wallet secret): not built, because Distilled does not build
  it either. `wallet_secret` is read and not used.
- **L1 vector regeneration** needs `@polymarket/clob-client` and `ethers` installed
  outside the repo (`/tmp/l1vec`, see the script header). `dl signed-rest-vectors`
  skips l1.lua when they are absent.
- **`verify/features/parity.md`** was not committed (it is a shared file). The
  orchestrator should regenerate it.

## Open problems

- Coinbase nonces come from `host.random`. The default host uses a 31-bit Park-Miller
  generator, so a host field for real random bytes is proposed (STATUS 28).
- `docs/interfaces.md` should list the `sign` and `accept_failure` hooks.
  `verify/features/README.md` should get a row for `signed-rest.md`.
