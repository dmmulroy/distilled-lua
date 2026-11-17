# Task 14 (crypto): done

## What was built

- `lua/distilled/crypto/` (pure Lua 5.1, no `bit`/`bit32`, one code path on every runtime):
  - `bytes.lua`: 256x256 XOR/AND tables, `NA` (NOT a AND b), carry tables, and
    `bytes.linear` (an XOR of rotations/shifts as per-byte tables, deduplicated).
  - `codegen.lua`: helpers to write and compile the generated compression functions.
  - `sha2.lua` (SHA-224/256/384/512), `sha1.lua`, `md5.lua`, `keccak.lua` (Keccak-256
    and SHA3-256): compression functions generated as Lua source on first use (source
    inspectable with `.source()`), words kept as bytes, every bitwise op a lookup.
  - `crc32.lua` (CRC-32 and CRC-32C, continuable, `crc32.bytes`), `hmac.lua` (any hash,
    secret keys), `hex.lua`, `base64.lua` (std + url, padded or not, strict decoders
    returning `InvalidInput`), `init.lua` (`distilled.crypto` index, `crypto.equal`).
- `lua/distilled/sigv4.lua`: port of `../distilled/packages/aws4signer/src/index.ts`
  (sign in headers or query, presign, session token in or after the signature,
  `UNSIGNED-PAYLOAD` for S3, `hash_payload`, single/double path encoding, guessed
  service/region, `signing_key`, `canonical_request`, optional caller-owned
  `key_cache`), including the WHATWG `URL`/`URLSearchParams` behaviour aws4fetch relies
  on (escape sets, dot segments, default ports, UTF-8 repair with U+FFFD, `set()`
  re-serialisation).
- Specs: `spec/crypto_spec.lua` (23 tests), `spec/sigv4_spec.lua` (22 tests); vectors
  `spec/golden/crypto/vectors.lua` (node:crypto/Buffer/zlib), `spec/golden/sigv4/vectors.lua`
  (Distilled's aws4signer, cross-checked against aws4fetch, plus the AWS SigV4 suite).
- Helpers: `verify/dl crypto-bench` (`verify/lib/crypto_bench.lua`), `verify/dl
  crypto-vectors` (`verify/lib/crypto_vectors.mjs`, `verify/lib/sigv4_vectors.mjs`).
- Docs: `docs/interfaces.md` sections `distilled.crypto` and `distilled.sigv4`;
  `verify/features/crypto.md`; `STATUS.md` section 14.

## Requirement by requirement

1. SHA-256, SHA-1, HMAC-SHA256, HMAC-SHA1, base64/base64url, hex: done (plus SHA-224/384/
   512, MD5, CRC-32/32C, SHA3-256, Keccak-256). Vectors: FIPS 180-4 examples, RFC 1321
   suite, RFC 4231 cases 1-7 (all four SHA-2 sizes, case 5 truncated), RFC 2202 (MD5 and
   SHA-1), RFC 4648 section 10, RFC 3720 CRC-32C, FIPS 202 / Ethereum Keccak values, and
   seeded random inputs at every block-boundary length (0-1000 bytes; HMAC keys 0-200
   bytes) diffed against node:crypto (committed, regenerated deterministically).
   Throughput measured under each runtime (below): SHA-256 of 1 MB takes 3.8 s in Rex.
2. Survey done (STATUS.md section 14, "Survey"): ECDSA P-256 (Coinbase, ACME, AWS login
   DPoP, SigV4A), Ed25519 (Coinbase), RSA RS256 (GitHub App, GCP service accounts,
   ACME) and secure random bytes are needed later and not implemented (no elliptic
   curves in this task, as the brief says). MD5 (Mailchimp, S3 Content-MD5) and CRC-32
   (S3 checksums) turned out to be needed and are implemented. SHA-512 and Keccak-256
   were cheap with the same machinery and are implemented (no package needs Keccak
   today: Distilled's Polymarket does not produce EIP-712 signatures).
3. `distilled.sigv4`: done with the brief's interface (`sign{ request, credentials,
   region, service, now_epoch }`); returns the signed request (a copy) whose `headers`
   are the signed headers, since presigning changes the URL. aws4signer's tests are
   ported (AWS docs S3 header and query examples, R2 presign, relative URL failure),
   its aws4fetch comparison cases are all in the vectors (plus 32 edge cases), and the
   AWS SigV4 test suite: 28 cases, 26 reproduce the published signature; `get-space`
   and `get-utf8` differ exactly as Distilled and aws4fetch do (they encode the path
   twice outside S3), which the spec asserts.

## Commands run and their output (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl fmt --check; echo "fmt exit $?"
fmt exit 0

$ verify/dl test
...
== summary
  lua: ok 1093 passed, 6 pending [Lua 5.5]
  luajit: ok 1093 passed, 6 pending [luajit]
  rex: ok 1086 passed, 9 pending [rex]
(the pending tests belong to other areas: HTTP specs without --http, etc.)

$ verify/dl test crypto      -> lua/luajit/rex: ok 23 passed
$ verify/dl test sigv4       -> lua/luajit/rex: ok 22 passed

$ verify/dl crypto-vectors && git status --short spec/golden
wrote .../spec/golden/crypto/vectors.lua
wrote .../spec/golden/sigv4/vectors.lua: 52 cases, suite 26/28 reproduced by Distilled
(no changes: the committed vectors are exactly Node's output)

$ verify/dl crypto-bench
Lua 5.5  setup (tables + generated code): 0.032 s
Lua 5.5  md5     1,000,000 bytes:   0.15 s    6.86 MB/s  ok
Lua 5.5  sha1    1,000,000 bytes:   0.33 s    2.99 MB/s  ok
Lua 5.5  sha256  1,000,000 bytes:   0.75 s    1.34 MB/s  ok
Lua 5.5  sha512  1,000,000 bytes:   1.05 s    0.95 MB/s  ok
Lua 5.5  crc32   1,000,000 bytes:   0.03 s   30.33 MB/s  ok
Lua 5.5  sha3      100,000 bytes:   0.12 s    0.85 MB/s  ok
Lua 5.5  hmac-sha256 short message: 0.221 ms each
Lua 5.5  sigv4.sign small JSON request: 1.48 ms each
Lua 5.5  sigv4.sign with key_cache: 0.62 ms each
luajit   setup (tables + generated code): 0.012 s
luajit   md5     1,000,000 bytes:   0.12 s    8.52 MB/s  ok
luajit   sha1    1,000,000 bytes:   0.11 s    8.72 MB/s  ok
luajit   sha256  1,000,000 bytes:   0.43 s    2.32 MB/s  ok
luajit   sha512  1,000,000 bytes:   0.54 s    1.86 MB/s  ok
luajit   crc32   1,000,000 bytes:   0.01 s   67.34 MB/s  ok
luajit   sha3      100,000 bytes:   0.14 s    0.73 MB/s  ok
luajit   hmac-sha256 short message: 0.143 ms each
luajit   sigv4.sign small JSON request: 0.82 ms each
luajit   sigv4.sign with key_cache: 0.36 ms each
rex      setup (tables + generated code): 0.113 s
rex      md5     1,000,000 bytes:   1.01 s    0.99 MB/s  ok
rex      sha1    1,000,000 bytes:   2.47 s    0.40 MB/s  ok
rex      sha256  1,000,000 bytes:   3.83 s    0.26 MB/s  ok
rex      sha512  1,000,000 bytes:   4.95 s    0.20 MB/s  ok
rex      crc32   1,000,000 bytes:   0.16 s    6.13 MB/s  ok
rex      sha3      100,000 bytes:   0.71 s    0.14 MB/s  ok
rex      hmac-sha256 short message: 1.023 ms each
rex      sigv4.sign small JSON request: 6.86 ms each
rex      sigv4.sign with key_cache: 2.93 ms each
```

(Each 1 MB digest is checked against the published one-million-"a" value; times are
`os.clock()`: CPU time on lua/luajit, wall time in Rex.)

How the design was chosen (measured in Rex, `rex do`): arithmetic emulation of 32-bit
ops with function calls gave SHA-256 at 0.06 MB/s, inlined arithmetic 0.09 MB/s, byte
tables 0.27 MB/s. A Rex micro-benchmark put a table lookup (~13 ns) at the cost of an
add (~9 ns), which is why lookups win.

## Proof-bar notes

- Error, empty and misuse paths are exercised: empty messages and keys, empty body
  (GET default, empty-string hash), base64/hex decode errors (`InvalidInput` with
  position, never the text), bad URLs and headers (`InvalidInput`, message never holds
  the header value), missing credentials (`ConfigError` with `key`, never the secret),
  unknown/mistyped arguments and bad times (raise), key cache bound (<= 16 entries,
  never keyed by the secret). No retry paths are affected by this task.
- No network in tests: the vectors are committed; Node runs only in `dl crypto-vectors`.

## Skipped, and why

- LuaJIT `bit` acceleration: allowed by the brief but not done; one tested path keeps
  results identical by construction. LuaJIT is already the fastest runtime here.
- Elliptic curves (ES256, Ed25519, secp256k1), RSA, SigV4A: out of scope per the brief;
  listed in the survey.
- AWS SigV4 suite cases with repeated or multi-line headers (`get-header-key-duplicate`,
  `get-header-value-order`, `get-header-value-multiline`): a Lua header table holds one
  value per name, and aws4fetch joins repeats with ", " where the suite expects ",".
- No live AWS call (proof bar: no live APIs); signatures are proven against Distilled,
  aws4fetch, and AWS's published examples/suite instead.

## Open problems (also in STATUS.md, section 14)

- **gopher-lua defect, new:** a multiple assignment to locals is sequential
  (`a, b = b, a` gives `b, b`). It already breaks `distilled.testing.random(seed)(n)` in
  Rex (task 03's `testing/init.lua` line 119, `m, n = 1, m`); fix proposed there.
  Should go into AGENTS.md's defect list.
- Proposed: a row for `crypto.md` in `verify/features/README.md`; moving sigv4's URL
  parser into `distilled.url` if another signer needs it; a `host.random_bytes` field
  for nonces/UUIDs.
- When the AWS protocol is built: pass a per-client `key_cache`, and keep presigned URLs
  and the `authorization` / `x-amz-security-token` headers out of span attributes (today
  only `url.template` and `server.address` are recorded, which is safe).
