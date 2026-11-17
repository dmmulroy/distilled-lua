# 24 pk-crypto: done

## What was built

Pure-Lua 5.1 public-key crypto under `lua/distilled/crypto/`, one implementation for lua
5.5, LuaJIT and gopher-lua:

- `bigint.lua`: 22-bit-limb integers with lazy carries; Montgomery contexts for any odd
  modulus up to 4,400 bits (`mod`, `mul`, `sqr`, `pow`, `inv`, add/sub). The products are
  generated as straight-line Lua per modulus (locals up to 60 limbs, table-indexed up to
  100). This is on by default on lua and gopher-lua and off on LuaJIT, where the loops
  are 6x faster. `ctx:compile()` forces it.
- `rsa.lua`: RSASSA-PKCS1-v1_5 with SHA-256/384/512 (RS256/384/512), CRT signing, and
  every signature checked with e before it is returned. Keys without CRT parameters work.
- `ecdsa.lua`: P-256 and secp256k1, RFC 6979 nonces, raw or DER output, optional low S,
  recovery ids, public-key recovery, compressed points. Fixed-base comb for k·G, built
  on the fourth use.
- `ed25519.lua`: RFC 8032 Ed25519 sign/verify (cofactorless, S < L).
- `asn1.lua`, `pem.lua`: DER read/write; PKCS #1, PKCS #8 (RSA, EC, Ed25519), SEC1, SPKI
  and PKCS #1 public keys, from PEM, DER or a secret.
- `jws.lua`, `jwt.lua`: compact and flattened JWS, ordered JSON (`jws.object`) so that
  headers and claims match the TypeScript output, JWK import/export, RFC 7638
  thumbprints, HS256/384/512, JWT encode/decode/verify.
- `key.lua`: key objects. Private parts sit in the metatable, so they never show in
  pairs, JSON or tostring.

Tokens that match Distilled's TypeScript byte for byte (tested): GitHub App JWT, GCP
service-account assertion, Coinbase CDP ES256 and EdDSA (from the base64 seed||public
secret), AWS login DPoP proof, ACME ES256 with jwk, ACME RS256 POST-as-GET with kid, and
the ACME HS256 External Account Binding.

Requirement 2's conditionals: Polymarket's SDK produces no L1 (EIP-712) signature, so
nothing needs secp256k1. Recovery is implemented anyway, since it was cheap. Coinbase
does need Ed25519, and it is done. PSS: no package uses it, so it is not implemented.

Also: `spec/crypto_pk_spec.lua` (34 tests); vectors in `spec/golden/crypto_pk/`
(`keys.json`, generated once by node; `vectors.lua`; `published.lua`); `verify/dl
pk-vectors` and `verify/dl pk-bench` (`verify/lib/pk_vectors.mjs`, `pk_published.mjs`,
`pk_bench.lua`); the section "Public-key crypto and JOSE" in `verify/features/crypto.md`;
STATUS section 24.

## Commands run (after `git merge main`)

```text
$ verify/dl models sync
...
models sync: 2253 models

$ verify/dl doctor
ok   lua: Lua 5.5.1 ...
ok   luajit: LuaJIT 2.1.1794386141 ...
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 ...
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
  lua: FAIL (exit 1) FAIL 1 failed, 1432 passed, 4 pending [Lua 5.5]
  luajit: FAIL (exit 1) FAIL 1 failed, 1432 passed, 4 pending [luajit]
  rex: ok 1421 passed, 8 pending [rex]
```

The one failure is not from this branch. On `main`, `spec/provider_spec.lua` (task 13)
lists the files in `providers/`, but task 16 added `providers/expo_eas.lua` and
`providers/linear.lua`, which the list does not name ("the list names every file in
providers/ (lua and luajit only)": expected "fly_io", got "expo_eas"). `git diff main --
providers spec/provider_spec.lua` is empty on this branch. The orchestrator should add
those two names to the list.

```text
$ lua spec/run.lua crypto          ok 57 passed [Lua 5.5]     (crypto_pk: 34, crypto: 23)
$ luajit spec/run.lua crypto       ok 57 passed [luajit]
$ rex do spec/run.lua filter=crypto   ok 57 passed [rex]   (crypto_pk about 26 s in Rex)

$ verify/dl pk-vectors && git status --short     # regenerates; no diff: deterministic
$ stylua --check lua/distilled/crypto/ spec/crypto_pk_spec.lua verify/lib/pk_bench.lua spec/golden/crypto_pk/
stylua ok

$ verify/dl pk-bench         (each signature checked against node:crypto)
Lua 5.5  RS256 2048 (CRT)       first   0.080 s   again   0.057 s   verify   0.011 s
Lua 5.5  RS256 3072 (CRT)       first   0.215 s   again   0.182 s   verify   0.018 s
Lua 5.5  RS256 4096 (CRT)       first   0.467 s   again   0.399 s   verify   0.041 s
Lua 5.5  ES256 P-256            first   0.026 s   again   0.005 s   verify   0.014 s
Lua 5.5  ES256K secp256k1       first   0.030 s   again   0.006 s   verify   0.017 s
Lua 5.5  EdDSA Ed25519          first   0.027 s   again   0.010 s   verify   0.013 s
luajit   RS256 2048 (CRT)       first   0.025 s   again   0.012 s   verify   0.003 s
luajit   RS256 3072 (CRT)       first   0.036 s   again   0.029 s   verify   0.005 s
luajit   RS256 4096 (CRT)       first   0.078 s   again   0.065 s   verify   0.011 s
luajit   ES256 P-256            first   0.012 s   again   0.002 s   verify   0.006 s
luajit   ES256K secp256k1       first   0.010 s   again   0.002 s   verify   0.004 s
luajit   EdDSA Ed25519          first   0.010 s   again   0.004 s   verify   0.003 s
rex      RS256 2048 (CRT)       first   0.399 s   again   0.287 s   verify   0.065 s
rex      RS256 3072 (CRT)       first   1.418 s   again   1.282 s   verify   0.131 s
rex      RS256 4096 (CRT)       first   3.219 s   again   2.768 s   verify   0.258 s
rex      ES256 P-256            first   0.111 s   again   0.023 s   verify   0.058 s
rex      ES256K secp256k1       first   0.125 s   again   0.026 s   verify   0.069 s
rex      EdDSA Ed25519          first   0.107 s   again   0.043 s   verify   0.055 s
```

Requirement 5: one RS256 signature with a 2048-bit key takes **0.40 s in gopher-lua** on
a fresh key (0.29 s when the key object is reused), 0.08 s in lua 5.5 and 0.025 s in
LuaJIT.

## Evidence (what the spec checks)

- Published vectors, extracted from the documents by a script, not typed in: RFC 6979
  A.2.5 (10 P-256 signatures, 5 hashes, byte-exact), RFC 8032 7.1 (5 tests incl. 1023
  bytes), RFC 7515 A.2 RS256 JWS (byte-exact) and A.3 ES256 (verified), RFC 8037 A
  (JWK, thumbprint, EdDSA JWS byte-exact), 32 tiny-secp256k1 RFC 6979 signatures (low S
  and recovery id; 8 recovered and verified).
- node:crypto differential: RS256/384/512 for 1024-4096-bit keys and Ed25519, byte for
  byte. ECDSA (16 vectors over two curves) byte for byte against RFC 6979 signatures
  that the Node script builds from node primitives and checks with `crypto.verify`
  (P1363 and DER). JWKs, private JWKs and thumbprints match node's export.
- Error, empty and edge paths: encrypted, garbage, truncated (prefixes) and mismatched
  keys; off-curve, out-of-range, compressed points; S ≥ L; altered messages and
  signatures; zero-length messages; exp/nbf/leeway; alg/key mismatch; `none`;
  HMAC/public-key algorithm confusion; key material never in tostring, JSON or error
  messages; misuse raises.
- Generated Montgomery code is compared with the loops for 2, 12, 47, 60, 62 and 100
  limbs, in place too, on every runtime. bigint is checked against BigInt.

## Skipped and why

- Recovery ids 2 and 3 (R.x ≥ n) are implemented but untested: no published vector has
  one (probability about 2^-128).
- Key generation and random nonces (ACME account keys, Coinbase `nonce`, DPoP `jti`)
  need host randomness, which the core does not have (task 14's proposal stands).
  `ecdsa.private_key(curve, random32)` turns random bytes into a key; RSA key generation
  is not implemented.
- RSA-PSS, P-384/P-521 (ES384/ES512): no package uses them.
- Not constant time, by design (documented).
- No live API calls. The tokens were compared with the TypeScript constructions run in
  Node, not sent to GitHub, Google or Coinbase.

## Open problems / proposals

- `spec/provider_spec.lua` on main misses `expo_eas` and `linear` (above).
- `distilled.crypto` (`init.lua`, task 14) could lazy-load the new modules.
  `docs/interfaces.md` could take the API list in STATUS section 24.
- I added `verify/dl` commands `pk-bench`/`pk-vectors` and the new file
  `lua/distilled/crypto/key.lua`; both are outside my brief's list (see STATUS).
