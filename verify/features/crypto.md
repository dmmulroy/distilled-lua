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
