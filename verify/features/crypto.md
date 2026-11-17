# Crypto and SigV4 (`distilled.crypto`, `distilled.sigv4`)

## Sub-features

- Hashes: SHA-224/256/384/512 (`crypto/sha2.lua`), SHA-1, MD5, SHA3-256 and Keccak-256
  (`crypto/keccak.lua`), CRC-32 and CRC-32C (`crypto/crc32.lua`, continuable).
- HMAC over any of those hashes (`crypto/hmac.lua`); keys may be `distilled.secret`s.
- Encodings: hex, base64 and base64url (strict decoders returning `InvalidInput`).
- `crypto.equal(a, b)`: compares every byte, for signature checks (webhooks).
- SigV4 (`sigv4.lua`): header signing, query presigning, session tokens (in the signature
  or appended), `UNSIGNED-PAYLOAD` / `hash_payload`, single/double path encoding,
  service and region guessed from the host, signing-key derivation and an optional
  caller-owned key cache. The URL handling is the part of WHATWG `URL` /
  `URLSearchParams` aws4fetch depends on (dot segments, escape sets, UTF-8 repair).

## How a user reaches it

```lua
local crypto = require("distilled.crypto")
crypto.hex.encode(crypto.hmac_sha256(secret, message))
crypto.base64.url_encode(crypto.sha256(body), true)

local sigv4 = require("distilled.sigv4")
local signed = assert(sigv4.sign{
  request = { method = "POST", url = url, headers = headers, body = body },
  credentials = { access_key_id = id, secret_access_key = distilled.secret(key) },
  region = "us-east-1", service = "sqs", now_epoch = host.epoch(),
})
local url = sigv4.presign{ url = object_url, credentials = creds, expires_in = 900,
                           now_epoch = os.time() }
```

Contracts: `docs/interfaces.md`, sections `distilled.crypto` and `distilled.sigv4`.

## Driving it with `dl`

- `verify/dl test crypto` (`spec/crypto_spec.lua`): FIPS 180 / RFC 1321 / FIPS 202 /
  RFC 4231 / RFC 2202 / RFC 4648 / RFC 3720 published vectors, plus seeded random
  inputs at every block-boundary length (0-1000 bytes, keys 0-200 bytes) diffed against
  `node:crypto`, `Buffer` and `zlib.crc32` (`spec/golden/crypto/vectors.lua`), decode
  error paths, misuse raises. Green under lua, luajit and rex.
- `verify/dl test sigv4` (`spec/sigv4_spec.lua`): aws4signer's own tests (AWS docs S3
  examples: `5c0d4ff2...`, `aeeed9bb...`), the documented signing-key example, 52
  requests signed by Distilled's aws4signer and aws4fetch compared byte for byte (URL,
  method, every header, and aws4fetch's `canonicalString()`), 28 cases of the published
  AWS SigV4 test suite (26 reproduce the published signature; `get-space` and `get-utf8`
  differ exactly as Distilled/aws4fetch do, since they encode paths twice), host guesses,
  presign, failures (`InvalidInput`, `ConfigError`, raises).
- `verify/dl crypto-vectors`: regenerates both vector files with Node (needs
  `../distilled` installed); the output is deterministic, so a clean `git diff` after it
  proves the committed vectors are Node's.
- `verify/dl crypto-bench`: throughput under all three runtimes, each digest checked
  against the published one-million-"a" value. Measured (this machine):

  | | lua 5.5 | luajit | rex (gopher-lua) |
  | --- | --- | --- | --- |
  | first use (tables + code generation) | 0.03 s | 0.01 s | 0.11 s |
  | MD5, 1 MB | 0.14 s | 0.11 s | 0.91 s |
  | SHA-1, 1 MB | 0.32 s | 0.10 s | 2.2 s |
  | SHA-256, 1 MB | 0.69 s | 0.40 s | 3.5 s |
  | SHA-512, 1 MB | 0.99 s | 0.52 s | 4.5 s |
  | SHA3-256, 100 KB | 0.12 s | 0.15 s | 0.69 s |
  | CRC-32, 1 MB | 0.03 s | 0.01 s | 0.16 s |
  | HMAC-SHA256, short message | 0.21 ms | 0.12 ms | 1.0 ms |
  | `sigv4.sign`, small JSON request | 1.4 ms | 0.8 ms | 7.6 ms |
  | same, with `key_cache` | 0.6 ms | 0.35 ms | 3.3 ms |

## Gotchas

- **Why byte tables.** No bitwise operators in 5.1 source and no bit library in
  gopher-lua. A 32-bit XOR emulated with arithmetic costs dozens of operations; in Rex a
  table lookup costs about the same as one arithmetic operation (~10-13 ns, measured), so
  words are kept as separate bytes and every AND/XOR/rotation is a lookup in a 256x256
  table (`crypto/bytes.lua`). That was 3x faster in Rex than inlined arithmetic
  emulation. Rotations and the SHA-2 sigma functions are GF(2)-linear, so each output
  byte is an XOR of per-input-byte tables (`bytes.linear`).
- **Generated code.** The compression functions are generated as Lua source on first use
  (unrolled 8 rounds for SHA-2, 5 for SHA-1, all 64 steps for MD5) and compiled with
  `compat.load`; `sha2.source("sha256")` etc. show it. Lua's 200-locals limit is why
  identical tables are shared and the SHA-2 message schedule is its own function.
- **gopher-lua multiple assignment.** `a, b = b, a` on locals gives `b, b` in Rex: a
  multiple assignment to locals is done one variable at a time, so a later right-hand
  side sees the earlier left-hand side's new value (`g, h = h + 0, g + 0` too). Upvalues,
  globals and table fields are fine. Use a temporary. Found here in
  `guess_service_region`'s region/service swap; `distilled.testing.random(seed)(n)` is
  hit by the same bug (see STATUS.md, task 14).
- LuaJIT's `bit` library is not used: one tested path everywhere. A `bit` path would make
  LuaJIT much faster but would be a second implementation to keep identical.
- Values are integers built with `math.floor`, so on 5.5 they stay integer subtypes and
  `string.format("%02x")` / table keys behave the same as on 5.1.
- SigV4 header values are bytes: aws4fetch sees JavaScript strings, so its `\s+`
  collapsing also covers U+00A0; here only ASCII whitespace is collapsed.

# Public-key crypto and JOSE (task 24)

## Sub-features

- `crypto/bigint.lua`: non-negative big integers in 22-bit limbs (doubles only) and
  Montgomery arithmetic modulo any odd number up to 4,400 bits: `mod`, `mul`, `sqr`,
  `pow` (4-bit windows), `inv` (Fermat), add/sub/neg.
- `crypto/rsa.lua`: RSASSA-PKCS1-v1_5 sign/verify with SHA-256/384/512 (RS256/384/512),
  CRT when the key has p, q (every PEM does), plain d otherwise. Each signature is checked
  with e before it is returned. PSS is not implemented: no package uses it.
- `crypto/ecdsa.lua`: P-256 (ES256) and secp256k1 (ES256K), RFC 6979 deterministic
  nonces, raw `r || s` or DER output, optional low S, recovery ids and public-key
  recovery (Ethereum-style signing has all it needs from here plus `keccak256`).
- `crypto/ed25519.lua`: Ed25519 (RFC 8032) sign/verify, cofactorless verification with
  S < L, as OpenSSL does.
- `crypto/asn1.lua`, `crypto/pem.lua`: DER reading/writing and the key files the packages
  take: PKCS #1 (`RSA PRIVATE KEY`, GitHub Apps), PKCS #8 (`PRIVATE KEY`: RSA for GCP
  service accounts, EC, Ed25519), SEC1 (`EC PRIVATE KEY`: Coinbase CDP, AWS login DPoP),
  SPKI and PKCS #1 public keys; PEM text, DER bytes or a `distilled.secret`; literal
  `\n` in pasted keys; a leading `EC PARAMETERS` block. Encrypted keys fail.
- `crypto/jws.lua`: compact and flattened JWS, ordered JSON (`jws.object`) so headers
  and claims come out in the order the TypeScript object literals have, JWK import and
  export, RFC 7638 thumbprints, HS256/384/512.
- `crypto/jwt.lua`: `jwt.encode` (alg first, then the caller's header fields; default
  `{"alg","typ":"JWT"}`), `jwt.decode`, `jwt.verify` (signature, alg, `exp`, `nbf`).
- `crypto/key.lua`: key objects. Private fields live in the key's metatable (like
  `distilled.secret`), so `pairs`, dumpers and `json.encode` see only public fields and
  `tostring` is `<rsa private key, 2048 bits>`.

**Not constant time.** Running time depends on the key and the message. An interpreter
gives no timing guarantees anyway. This code signs requests from a client. Do not use it
as a signing service where an attacker can time many signatures made with one key.

## How a user reaches it

```lua
local pem = require("distilled.crypto.pem")
local jws = require("distilled.crypto.jws")
local jwt = require("distilled.crypto.jwt")

-- GitHub App (github/src/app.ts): RS256, {"alg","typ"} then {"iss","iat","exp"}
local key = assert(pem.private_key(distilled.secret(app_pem)))   -- parse once, keep
local iat = os.time() - 60
local token = assert(jwt.encode{ key = key,
  claims = jws.object("iss", tostring(app_id), "iat", iat, "exp", iat + 600) })

-- GCP service account (from-service-account-key.ts)
jwt.encode{ key = sa_key, header = jws.object("typ", "JWT", "kid", private_key_id),
  claims = jws.object("iss", email, "scope", scope, "aud", token_url,
                      "iat", now, "exp", now + 3600) }

-- Coinbase CDP: ES256 from an EC PEM, or EdDSA from the base64 seed || public secret
local raw = crypto.base64.decode(secret_b64)
local cdp = require("distilled.crypto.ed25519").private_key(raw:sub(1, 32))
jwt.encode{ key = cdp, header = jws.object("kid", id, "typ", "JWT", "nonce", nonce),
  claims = jws.object("sub", id, "iss", "cdp", "aud", { "cdp_service" },
                      "nbf", now, "exp", now + 120, "uri", method .. " " .. host_path) }

-- ACME (acme/src/jose.ts): flattened JWS; no payload = POST-as-GET
jws.flattened{ key = account_key,
  header = jws.object("nonce", nonce, "url", url, "jwk", jws.public_jwk(account_key)),
  payload = jws.object("termsOfServiceAgreed", true) }
jws.thumbprint(account_key)                      -- key authorizations, DNS-01

-- secp256k1 with recovery (EIP-191/712 style; v = 27 + recid)
local sig, recid = ecdsa.sign_digest(k, crypto.keccak256(msg), { low_s = true })
```

Errors are `InvalidInput` (bad key file, bad JWK, a key that cannot sign with the
requested alg), and their messages name the format, never the content. Verification
returns `false` (or `nil, InvalidInput` from `jws.verify`/`jwt.verify`). Wrong argument
types raise.

## Driving it with `dl`

- `verify/dl test crypto_pk` (`spec/crypto_pk_spec.lua`, 34 tests, green under lua,
  luajit and rex; Rex takes about 26 s):
  - published vectors, extracted from the documents by `verify/lib/pk_published.mjs`
    into `spec/golden/crypto_pk/published.lua`: RFC 6979 A.2.5 (P-256, SHA-1/224/256/
    384/512, "sample"/"test", byte for byte), RFC 8032 7.1 (TEST 1, 2, 3, 1024, SHA(abc)),
    RFC 7515 A.2 (the RS256 JWS, byte for byte) and A.3 (ES256, verified), RFC 8037 A
    (Ed25519 JWK, thumbprint, EdDSA JWS byte for byte), and 32 tiny-secp256k1 RFC 6979
    secp256k1 signatures with low S and recovery ids (signing all, recovering 8).
  - node:crypto differential (`spec/golden/crypto_pk/vectors.lua` from
    `verify/lib/pk_vectors.mjs`, for keys generated once into `keys.json`): RS256/384/512
    with 1024-4096-bit keys and Ed25519, byte for byte. For ECDSA the script computes the
    RFC 6979 signature from node primitives (HMAC, `createECDH` for k·G, BigInt) and checks
    it with `crypto.verify` in P1363 and DER, so a Lua signature that is byte-equal to it
    is one node:crypto accepts. Also JWKs and private JWKs as node exports them, and
    thumbprints.
  - the tokens Distilled mints, rebuilt in Lua and compared byte for byte: GitHub App
    JWT, GCP assertion, Coinbase CDP ES256 and EdDSA, AWS login DPoP proof, ACME ES256
    (jwk), RS256 POST-as-GET (kid), HS256 External Account Binding.
  - failures: encrypted, truncated (every 7th prefix), mismatched and garbage keys,
    off-curve and out-of-range points, S ≥ L, altered messages and signatures, `exp`,
    `nbf`, alg/key mismatch, `none`, HMAC/public-key algorithm confusion, keys never in
    `tostring`, JSON or error messages.
  - bigint against BigInt; generated products against the loops for 2-100 limbs.
- `verify/dl pk-vectors`: regenerates both vector files. It needs Node and, for the
  published file, the network. The output is deterministic: a clean `git diff` after it
  shows the committed vectors are Node's and the RFCs'.
- `verify/dl pk-bench`: signing times per runtime, each signature checked against the
  node:crypto vector. Measured on this machine ("first" includes parsing the PEM and setting up
  the key; "again" reuses the key object):

  | | lua 5.5 | luajit | rex (gopher-lua) |
  | --- | --- | --- | --- |
  | RS256, 2048-bit key, first / again | 0.080 / 0.057 s | 0.025 / 0.012 s | 0.40 / 0.29 s |
  | RS256, 3072-bit key, again | 0.18 s | 0.029 s | 1.3 s |
  | RS256, 4096-bit key, again | 0.40 s | 0.065 s | 2.8 s |
  | RS256 verify, 2048 | 0.011 s | 0.003 s | 0.065 s |
  | ES256 sign, first / again | 0.026 / 0.005 s | 0.012 / 0.002 s | 0.11 / 0.023 s |
  | ES256 verify | 0.014 s | 0.006 s | 0.058 s |
  | ES256K sign, again | 0.006 s | 0.002 s | 0.026 s |
  | EdDSA sign, first / again | 0.027 / 0.010 s | 0.010 / 0.004 s | 0.11 / 0.043 s |

  An RS256 token refresh in Rex (GitHub App, GCP) costs about 0.3-0.4 s.

## Gotchas

- **22-bit limbs, lazy carries.** A product of two 22-bit limbs is below 2^44, so 2^9 of
  them can be summed exactly in a double. Each column of a product is accumulated
  before any carry is taken. The bound is 200 limbs (4,400 bits).
- **Generated code, but not on LuaJIT.** For a modulus of up to 60 limbs, Montgomery
  `mul`/`sqr` are generated as straight-line Lua for that one modulus: limbs in locals,
  the modulus as constants. Up to 100 limbs the generated code indexes tables instead.
  That is 2-3x faster in lua 5.5 and gopher-lua. LuaJIT JIT-compiles the loops but not
  functions this long, so the generated code is 6x slower there, and `bigint.GENERATE`
  is off on LuaJIT. A context compiles after 256 products, or at once for a long
  exponent. RSA public-exponent checks (about 35 products) stay on the loops.
  `ctx:compile()` forces it. The spec compares both versions on every runtime.
- **Fixed-base comb.** k·G uses a table of v·16^w·G in affine form (960 points per
  curve). Building it costs about six scalar multiplications, so it is built on the
  fourth use of G in a process (`ecdsa.COMB_AFTER`). A script that signs once does not
  pay for it.
- **RSA without CRT** (a JWK with only n, e, d) is about 3x slower and is supported.
- **JSON order.** `json.encode` sorts keys, but JOSE needs the TypeScript insertion
  order to reproduce tokens, so `jws.object(k, v, ...)` is an ordered object. Plain
  tables inside it are still sorted. RFC 7638's canonical order happens to be sorted
  order.
- Recovery ids 2 and 3 (R.x ≥ n, probability about 2^-128) are implemented but no
  published vector has one.
- Randomness is not here. Key generation (ACME `generateAccountKey`), Coinbase's nonce
  and DPoP's `jti` need random bytes from the host. `ecdsa.private_key(curve,
  random_32_bytes)` makes a P-256 or secp256k1 key from them. RSA key generation is not
  implemented.
