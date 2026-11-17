# Task 24: public-key crypto in pure Lua (RSA, ECDSA, Ed25519, secp256k1) and JWT/JWS

Read `tasks/10-parity-overview.md`, `STATUS.md` (section 14) and
`verify/features/crypto.md` first. Task 14 built SHA-1/2, MD5, HMAC, keccak, base64.

Needed by: GCP / Google Workspace service accounts (RS256 JWT), GitHub Apps (RS256),
ACME (ES256/RS256 JWS, `../distilled/packages/acme/src/jose.ts`), Coinbase (ES256 or Ed25519
JWT), Polymarket (secp256k1 / EIP-712 signatures), Stripe webhooks (HMAC, done). See
`../distilled/packages/core/src/crypto.ts` and the packages' `src/*.ts`.

## Files you own

```text
lua/distilled/crypto/bigint.lua, rsa.lua, ecdsa.lua (P-256, secp256k1), ed25519.lua,
  asn1.lua / pem.lua (PKCS#1, PKCS#8, SEC1, SPKI parsing), jwt.lua / jws.lua   (new)
spec/crypto_pk_spec.lua (new) and manifest; golden vectors under spec/golden/
verify/features/crypto.md (append sections)
STATUS.md (section "24 pk-crypto")
```

## Requirements

1. Arbitrary-precision integers sized for 2048/4096-bit RSA in pure Lua 5.1 (exact limb
   arithmetic in doubles, e.g. 24-bit limbs; Montgomery or Barrett for modexp).
   RSA PKCS#1 v1.5 SHA-256 sign/verify (RS256); PSS only if a package needs it.
2. ECDSA over P-256 (ES256) and secp256k1 with RFC 6979 deterministic nonces (tests
   byte-exact), public-key recovery for secp256k1 if Polymarket needs it; Ed25519 if
   Coinbase needs it. Constant time is not a goal; say so in the docs.
3. PEM/DER parsing for the key formats those packages accept (service-account JSON
   `private_key`, GitHub App PEM, EC keys). JWT/JWS compact serialisation helpers that
   match what the TS packages produce (header order, base64url, claims).
4. Vectors: RFC 8037/6979/8032 cases plus Node `crypto.sign` differential tests; keys
   generated once and committed under `spec/golden/`.
5. Measure: one RS256 signature with a 2048-bit key per runtime (must be usable once per
   token refresh in gopher-lua; report seconds).
