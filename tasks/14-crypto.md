# Task 14: pure-Lua crypto primitives and the AWS SigV4 signer

Read `tasks/10-parity-overview.md` first. Signed-request providers (AWS, Tencent Cloud TC3,
Polymarket, Coinbase, OVH, ...) need hashing and HMAC in pure Lua 5.1 with no bitwise
operators (AGENTS.md hard rules: same file on lua 5.5, luajit, gopher-lua).

## Files you own

```text
lua/distilled/crypto/*.lua (new)   sha256, sha1, md5 (if needed), hmac, base64, base64url, hex
lua/distilled/sigv4.lua (new)      AWS Signature Version 4 (port of ../distilled/packages/aws4signer)
spec/crypto_spec.lua, spec/sigv4_spec.lua (new) and manifest
verify/features/crypto.md (new)
STATUS.md (section "14 crypto")
```

## Requirements

1. SHA-256, SHA-1, HMAC-SHA256, HMAC-SHA1, base64 / base64url encode+decode, hex. Use
   arithmetic 32-bit operations that are exact in doubles; you may use `bit` (LuaJIT) or
   `bit32` when present for speed, but the pure path must be the tested default on every
   runtime and give identical results. Test vectors: NIST/RFC 4231/RFC 2202, plus random
   inputs diffed against `openssl dgst` / `node:crypto` (a `verify/dl` helper or a spec that
   reads precomputed vectors you commit). Measure throughput under each runtime (a 1 MB
   body hash must finish in reasonable time in gopher-lua; report numbers).
2. Check which packages need more (ECDSA P-256/ES256 for Coinbase JWT, Ed25519, EIP-712 /
   keccak for Polymarket, SHA-512 ...): `grep -l crypto ../distilled/packages/*/src/*.ts`
   and core `crypto.ts`. Implement keccak-256 and SHA-512 if cheap; report the rest
   (do not implement elliptic curves in this task).
3. `distilled.sigv4`: port `../distilled/packages/aws4signer` (canonical request, string to
   sign, signing key, presign if it has it, `x-amz-content-sha256`, session token,
   unsigned payload). Port its tests and the AWS SigV4 test suite vectors it uses.
   Interface: `sigv4.sign{ request = <distilled request table>, credentials = {
   access_key_id, secret_access_key, session_token? }, region, service, now_epoch }` ->
   signed request headers. Document it in `docs/interfaces.md` (append a section).
