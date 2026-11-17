# Signed REST: Coinbase CDP and Polymarket (`clients/coinbase`, `clients/polymarket`)

The Lua side of `@distilled.cloud/coinbase` and `@distilled.cloud/polymarket`: plain
REST/JSON clients whose requests are signed per request by hand-written glue.

| package | models | operations (TS / Lua) | glue |
| --- | --- | --- | --- |
| coinbase | 1 (`cdp`) | 178 / 178 | `providers/glue/coinbase.lua` |
| polymarket | 7 (`bridge`, `clob`, `combos_rfq`, `data`, `gamma`, `perps`, `relayer`) | 223 / 223 | `providers/glue/polymarket.lua`, `polymarket_clob.lua` |

## The REST protocol hooks (task 28)

`rest.new{ glue = ... }` takes two more glue functions (`lua/distilled/protocol/rest.lua`,
listed in `gen/provider_ext.lua` `ext.HOOKS`):

- `sign(request, settings, { host, op, base_url }) -> request | nil, err`: called last in
  `protocol.encode`, on the built request (method, URL with query, lower-case headers,
  body text). Retries call `encode` again, so every attempt is signed afresh.
- `accept_failure{ status, headers, body, non_json, op } -> true`: decode a >= 400 answer
  as the success value.

Provider-spec header names may now contain `_` and `.` (Polymarket's `RELAYER_API_KEY`).

## Coinbase (packages/coinbase/src/protocol.ts, credentials.ts, errors.ts)

- Options: `api_key_id` (`CDP_API_KEY_ID`, else `CDP_API_KEY_NAME`), `api_key_secret`
  (`CDP_API_KEY_SECRET`), `wallet_secret` (`CDP_WALLET_SECRET`, read, unused as in
  Distilled), `base_url` (default `https://api.cdp.coinbase.com/platform`).
- `Authorization: Bearer <JWT>` per request. Header `{"alg","kid","typ":"JWT","nonce"}`,
  claims `{"sub","iss":"cdp","aud":["cdp_service"],"nbf","exp":nbf+120,"uri":"<METHOD>
  <host><path>"}` (URL host lower-cased, default port dropped, no query). A secret with
  `-----BEGIN` is a PEM key signed ES256; else base64 (read like `Buffer.from`) of 64
  bytes is an Ed25519 seed + public key, signed EdDSA; else ConfigError. `nbf` is
  `host.epoch()`, the nonce 16 bytes from `host.random`. Parsed keys are cached by the
  SHA-256 of the secret (16 entries).
- Failures (`matchError`): the 49 `errorType` classes (fields `error_type`,
  `error_message`, `correlation_id`, `error_link`; `code` = errorType), then the standard
  types (`not_found` -> NotFound, ...), then the status map, 402 PaymentRequired, unmapped
  5xx InternalServerError, else UnknownCoinbaseError. A failure body with `isValid` or
  `success` is the value.

## Polymarket (packages/polymarket/src/protocol.ts, credentials.ts, signing.ts)

- Three credential groups, each all or nothing, checked by every API (as
  `CredentialsFromEnv`): CLOB (`clob_address`/`POLY_ADDRESS`, `clob_api_key`/`CLOB_API_KEY`,
  `clob_secret`/`CLOB_SECRET`, `clob_passphrase`/`CLOB_PASS_PHRASE`), relayer
  (`relayer_address`, `relayer_api_key`), Perps (`perps_proxy`, `perps_secret`).
  `CLOB_API_URL` moves the CLOB host; each API has its own default host.
- L2 (CLOB and Combos RFQ, when the CLOB group is set): `POLY_ADDRESS`, `POLY_SIGNATURE`
  (base64url with padding of HMAC-SHA256(base64 secret, timestamp .. METHOD .. path ..
  body); path below the base URL without query), `POLY_TIMESTAMP`, `POLY_API_KEY`,
  `POLY_PASSPHRASE`. Relayer: `RELAYER_API_KEY`, `RELAYER_API_KEY_ADDRESS`. Perps:
  `POLYMARKET-PROXY`, `POLYMARKET-SECRET`. 413 is PayloadTooLarge.
- **L1 (beyond Distilled, which does not sign L1)**: with `l1_private_key`
  (`POLY_PRIVATE_KEY`, 32 bytes hex), `create_api_key` and `derive_api_key` carry
  clob-client's `createL1Headers`: `POLY_ADDRESS` (EIP-55), `POLY_SIGNATURE` (EIP-712
  ClobAuth in domain ClobAuthDomain/1/`chain_id`, secp256k1, low s, `0x..r s v`),
  `POLY_TIMESTAMP`, `POLY_NONCE` (`l1_nonce`, default 0). `chain_id` (`POLY_CHAIN_ID`)
  defaults to 137.

## Evidence

- `spec/signed_rest_conform_spec.lua` (61 cases) against `spec/golden/signed_rest/conform.lua`,
  written by `verify/lib/signed_rest_conform.mjs` from Distilled's own code
  (`API.encodeRequest` and calls over a stub HttpClient; Date, TestClock and
  `crypto.randomBytes` pinned): Coinbase EdDSA JWTs byte for byte, ES256 header and claims
  byte for byte with the signature verified; 29 failure outcomes; Polymarket L2 headers
  byte for byte, relayer/Perps headers, 6 failure outcomes.
- `spec/signed_rest_spec.lua`: 40 L1 header sets equal to `@polymarket/clob-client`
  5.8.1 with ethers 5.7.2 (`verify/lib/polymarket_l1_vectors.mjs`, 5 keys x 2 chains x 4
  nonces up to 2^256-1); the official L2 vector; env names; incomplete groups in all 7
  APIs; retries re-signed (new nonce / timestamp); missing and broken keys as
  ConfigErrors that hold no secret; `accept_failure`.
- `verify/dl signed-rest-vectors` regenerates both golden files (deterministic).
- `verify/dl gen-diff coinbase`, `verify/dl gen-diff polymarket`.

## Intended differences

| Difference | Lua | Distilled | Why |
| --- | --- | --- | --- |
| JSON body key order | sorted (`distilled.json`) | schema order | the JSON codec has one order; bodies compare as JSON. The L2 signature covers Lua's exact body; the golden file has Distilled's `signL2` over that body and it matches |
| ES256 signature bytes | RFC 6979 (deterministic) | node:crypto (random k) | both verify with the key; header and claims are equal |
| Coinbase errorType class message | `errorMessage` | `""` (errorMessage is a field) | a message must say something |
| Non-envelope JSON failure message | re-serialized with sorted keys | `JSON.stringify` (wire order) | the glue sees the decoded body |
| Broken-key messages | `<detail>: <distilled.crypto message>` | `<detail>: <node:crypto message>` | different libraries; the detail before `:` is equal |
| RSA or P-384 PEM secret | ConfigError (cannot sign ES256 / not a valid EC key) | signs, then truncates into an invalid token | fail early |
| `accept_failure` value | strict validation applies | not validated | the same decode path as a 2xx |
| Nonce quality | `host.random` (the default host: Park-Miller, 31-bit state) | `crypto.randomBytes` | the brief asks for host.random; a host can supply a stronger `random` |
