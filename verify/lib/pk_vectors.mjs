// Writes spec/golden/crypto_pk/vectors.lua: public-key signatures computed with node:crypto
// for the keys in spec/golden/crypto_pk/keys.json, which this script generates once (when
// the file is missing) and then only reads. Everything else is deterministic, so
// re-running `verify/dl pk-vectors` changes nothing unless this script or the keys change.
//
//   rsa       RS256/384/512 (PKCS #1 v1.5) of seeded random messages, 1024-4096-bit keys
//   ed25519   crypto.sign(null, ...) of seeded random messages
//   ecdsa     RFC 6979 signatures for P-256 and secp256k1: the nonce from HMAC-DRBG
//             (node:crypto HMAC), k*G from crypto.createECDH, s with BigInt; every
//             signature is then checked with crypto.verify (P1363 and DER), so a Lua
//             signature equal to it is one node:crypto accepts
//   tokens    the JWTs / JWSs Distilled's packages mint (GitHub App, GCP service account,
//             Coinbase CDP ES256 and EdDSA, AWS login DPoP, ACME, EAB), built with the
//             same JSON.stringify calls as the TypeScript sources
//   bigint    products, remainders and powers checked with BigInt
import {
  createECDH,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  verify,
} from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import assert from "node:assert/strict";

const [keysPath, out] = process.argv.slice(2);
if (!keysPath || !out) throw new Error("usage: node pk_vectors.mjs <keys.json> <out.lua>");

// ------------------------------------------------------------------------------------
// keys: generated once
// ------------------------------------------------------------------------------------

if (!existsSync(keysPath)) {
  const keys = {};
  const pem = (k, type) => k.export({ format: "pem", type });
  for (const bits of [1024, 2048, 3072, 4096]) {
    const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: bits });
    keys[`rsa${bits}`] = {
      pkcs1: pem(privateKey, "pkcs1"),
      pkcs8: pem(privateKey, "pkcs8"),
      spki: publicKey.export({ format: "pem", type: "spki" }),
      pkcs1_public: publicKey.export({ format: "pem", type: "pkcs1" }),
    };
  }
  for (const [name, curve] of [
    ["p256", "prime256v1"],
    ["secp256k1", "secp256k1"],
  ]) {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: curve });
    keys[name] = {
      sec1: pem(privateKey, "sec1"),
      pkcs8: pem(privateKey, "pkcs8"),
      spki: publicKey.export({ format: "pem", type: "spki" }),
    };
  }
  const ed = generateKeyPairSync("ed25519");
  keys.ed25519 = {
    pkcs8: pem(ed.privateKey, "pkcs8"),
    spki: ed.publicKey.export({ format: "pem", type: "spki" }),
  };
  // an encrypted key, for the error path
  keys.encrypted = {
    pkcs8: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({
      format: "pem",
      type: "pkcs8",
      cipher: "aes-256-cbc",
      passphrase: "not-a-secret",
    }),
  };
  writeFileSync(keysPath, JSON.stringify(keys, null, 2) + "\n");
  console.log(`generated ${keysPath}`);
}
const KEYS = JSON.parse(readFileSync(keysPath, "utf8"));

// ------------------------------------------------------------------------------------
// helpers
// ------------------------------------------------------------------------------------

// Park-Miller, as distilled.testing.random and crypto_vectors.mjs
let seed = 20260516;
const next = () => (seed = (seed * 16807) % 2147483647);
const bytes = (n) => Buffer.from(Array.from({ length: n }, () => next() % 256));
const hex = (b) => Buffer.from(b).toString("hex");
const q = (s) => JSON.stringify(s);
const b64u = (b) => Buffer.from(b).toString("base64url");
const big = (b) => BigInt("0x" + (hex(b) || "0"));
const toBytes = (x, n) => Buffer.from(x.toString(16).padStart(n * 2, "0"), "hex");
const modpow = (b, e, m) => {
  let r = 1n;
  b %= m;
  while (e > 0n) {
    if (e & 1n) r = (r * b) % m;
    b = (b * b) % m;
    e >>= 1n;
  }
  return r;
};

const lines = [];
const w = (s) => lines.push(s);

// ------------------------------------------------------------------------------------
// ECDSA with RFC 6979 nonces, computed with node:crypto primitives
// ------------------------------------------------------------------------------------

const CURVES = {
  "P-256": {
    ecdh: "prime256v1",
    n: 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n,
  },
  secp256k1: {
    ecdh: "secp256k1",
    n: 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n,
  },
};

const hmac = (k, d) => createHmac("sha256", k).update(d).digest();

// RFC 6979 3.2 for a 256-bit order and HMAC-SHA256
function* nonces(n, d, digest) {
  const x = toBytes(d, 32);
  let h = big(digest);
  if (h >= n) h -= n;
  const hb = toBytes(h, 32);
  let V = Buffer.alloc(32, 1);
  let K = Buffer.alloc(32, 0);
  K = hmac(K, Buffer.concat([V, Buffer.from([0]), x, hb]));
  V = hmac(K, V);
  K = hmac(K, Buffer.concat([V, Buffer.from([1]), x, hb]));
  V = hmac(K, V);
  for (;;) {
    V = hmac(K, V);
    const k = big(V);
    if (k >= 1n && k < n) yield k;
    K = hmac(K, Buffer.concat([V, Buffer.from([0])]));
    V = hmac(K, V);
  }
}

const ecdsaSign = (curve, d, digest, lowS) => {
  const { ecdh, n } = CURVES[curve];
  const e = big(digest) % n;
  for (const k of nonces(n, d, digest)) {
    const point = createECDH(ecdh);
    point.setPrivateKey(toBytes(k, 32));
    const R = point.getPublicKey();
    const x = big(R.subarray(1, 33));
    const y = big(R.subarray(33, 65));
    const r = x % n;
    if (r === 0n) continue;
    let s = (modpow(k, n - 2n, n) * (e + r * d)) % n;
    if (s === 0n) continue;
    let recid = Number(y & 1n) + (x >= n ? 2 : 0);
    if (lowS && s > n / 2n) {
      s = n - s;
      recid ^= 1;
    }
    return { r, s, recid };
  }
};

// DER of r, s (what node:crypto signs by default)
const derInt = (x) => {
  let b = toBytes(x, 32);
  while (b.length > 1 && b[0] === 0 && b[1] < 0x80) b = b.subarray(1);
  if (b[0] >= 0x80) b = Buffer.concat([Buffer.from([0]), b]);
  return Buffer.concat([Buffer.from([2, b.length]), b]);
};
const der = (r, s) => {
  const body = Buffer.concat([derInt(r), derInt(s)]);
  return Buffer.concat([Buffer.from([0x30, body.length]), body]);
};

const ecPrivate = (name) => {
  const key = createPrivateKey(KEYS[name].sec1);
  return { key, d: big(Buffer.from(key.export({ format: "jwk" }).d, "base64url")) };
};

// ES256 over a signing input, as a JWS wants it (raw r || s), checked by node:crypto
const es256 = (name, curve, input) => {
  const { key, d } = ecPrivate(name);
  const { r, s } = ecdsaSign(curve, d, createHash("sha256").update(input).digest(), false);
  const raw = Buffer.concat([toBytes(r, 32), toBytes(s, 32)]);
  assert.ok(verify("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }, raw));
  return raw;
};

// ------------------------------------------------------------------------------------
// output
// ------------------------------------------------------------------------------------

w("-- Generated by verify/lib/pk_vectors.mjs (node:crypto) from keys.json. Do not edit.");
w("return {");

// RSA
w("  rsa = {");
const rsaCases = [
  ["rsa1024", "sha256", 6],
  ["rsa2048", "sha256", 6],
  ["rsa2048", "sha384", 2],
  ["rsa2048", "sha512", 2],
  ["rsa3072", "sha256", 2],
  ["rsa4096", "sha256", 2],
];
const lengths = [0, 1, 55, 64, 100, 300, 1000];
let li = 0;
for (const [name, hash, count] of rsaCases) {
  const key = createPrivateKey(KEYS[name].pkcs1);
  for (let i = 0; i < count; i++) {
    const msg = bytes(lengths[li++ % lengths.length]);
    const sig = sign(hash, msg, key);
    assert.ok(verify(hash, msg, createPublicKey(key), sig));
    w(`    { key = ${q(name)}, hash = ${q(hash)}, message = ${q(hex(msg))}, signature = ${q(hex(sig))} },`);
  }
}
w("  },");

// Ed25519
w("  ed25519 = {");
{
  const key = createPrivateKey(KEYS.ed25519.pkcs8);
  for (let i = 0; i < 12; i++) {
    const msg = bytes(lengths[li++ % lengths.length]);
    w(`    { message = ${q(hex(msg))}, signature = ${q(hex(sign(null, msg, key)))} },`);
  }
}
w("  },");

// ECDSA
w("  ecdsa = {");
for (const [name, curve] of [
  ["p256", "P-256"],
  ["secp256k1", "secp256k1"],
]) {
  const { key, d } = ecPrivate(name);
  for (let i = 0; i < 8; i++) {
    const msg = bytes(lengths[li++ % lengths.length]);
    const digest = createHash("sha256").update(msg).digest();
    const lowS = curve === "secp256k1" && i % 2 === 1;
    const { r, s, recid } = ecdsaSign(curve, d, digest, lowS);
    const raw = Buffer.concat([toBytes(r, 32), toBytes(s, 32)]);
    assert.ok(verify("sha256", msg, { key, dsaEncoding: "ieee-p1363" }, raw));
    assert.ok(verify("sha256", msg, key, der(r, s)));
    w(
      `    { key = ${q(name)}, curve = ${q(curve)}, message = ${q(hex(msg))}, low_s = ${lowS}, signature = ${q(hex(raw))}, der = ${q(hex(der(r, s)))}, recovery_id = ${recid} },`,
    );
  }
}
w("  },");

// public keys as node:crypto exports them
w("  public = {");
for (const name of ["rsa2048", "p256", "secp256k1", "ed25519"]) {
  const pk = createPublicKey(KEYS[name].spki);
  const jwk = pk.export({ format: "jwk" });
  const canon =
    jwk.kty === "RSA"
      ? { e: jwk.e, kty: "RSA", n: jwk.n }
      : jwk.kty === "EC"
        ? { crv: jwk.crv, kty: "EC", x: jwk.x, y: jwk.y }
        : { crv: jwk.crv, kty: "OKP", x: jwk.x };
  const thumb = b64u(createHash("sha256").update(JSON.stringify(canon)).digest());
  const priv = createPrivateKey(KEYS[name].pkcs8 ?? KEYS[name].pkcs1).export({ format: "jwk" });
  w(
    `    ${name} = { jwk = ${q(JSON.stringify(jwk))}, private_jwk = ${q(JSON.stringify(priv))}, thumbprint = ${q(thumb)} },`,
  );
}
w("  },");

// tokens, built exactly as the TypeScript packages build them
w("  tokens = {");
const jsonB64 = (v) => b64u(Buffer.from(JSON.stringify(v)));
{
  // github/src/app.ts signJwt
  const iat = 1767225600 - 60;
  const signingInput = `${jsonB64({ alg: "RS256", typ: "JWT" })}.${jsonB64({ iss: String(123456), iat, exp: iat + 60 + 540 })}`;
  const sig = sign("sha256", Buffer.from(signingInput), createPrivateKey(KEYS.rsa2048.pkcs1));
  w(`    github_app = { app_id = "123456", iat = ${iat}, token = ${q(`${signingInput}.${b64u(sig)}`)} },`);
}
{
  // gcp/src/credential-providers/from-service-account-key.ts signAssertion
  const iat = 1767225600;
  const header = { alg: "RS256", typ: "JWT", ...("abc123" && { kid: "abc123" }) };
  const claims = {
    iss: "svc@project.iam.gserviceaccount.com",
    scope: ["https://www.googleapis.com/auth/cloud-platform"].join(" "),
    aud: "https://oauth2.googleapis.com/token",
    iat,
    exp: iat + 3600,
  };
  const signingInput = `${jsonB64(header)}.${jsonB64(claims)}`;
  const sig = sign("sha256", Buffer.from(signingInput), createPrivateKey(KEYS.rsa2048.pkcs8));
  w(`    gcp = { iat = ${iat}, token = ${q(`${signingInput}.${b64u(sig)}`)} },`);
}
{
  // coinbase/src/protocol.ts generateJwt (nonce fixed here; the package draws 16 random bytes)
  const now = 1767225600;
  const id = "organizations/org-id/apiKeys/key-id";
  const nonce = "0123456789abcdef0123456789abcdef";
  const payload = {
    sub: id,
    iss: "cdp",
    aud: ["cdp_service"],
    nbf: now,
    exp: now + 120,
    uri: "GET api.cdp.coinbase.com/platform/v2/evm/accounts",
  };
  for (const alg of ["ES256", "EdDSA"]) {
    const header = { alg, kid: id, typ: "JWT", nonce };
    const signingInput = `${jsonB64(header)}.${jsonB64(payload)}`;
    const sig =
      alg === "ES256"
        ? es256("p256", "P-256", signingInput)
        : sign(null, Buffer.from(signingInput), createPrivateKey(KEYS.ed25519.pkcs8));
    w(`    coinbase_${alg.toLowerCase()} = { token = ${q(`${signingInput}.${b64u(sig)}`)} },`);
  }
  // the Ed25519 secret as CDP issues it: base64 of seed || public key
  const jwk = createPrivateKey(KEYS.ed25519.pkcs8).export({ format: "jwk" });
  const secret = Buffer.concat([Buffer.from(jwk.d, "base64url"), Buffer.from(jwk.x, "base64url")]);
  w(`    coinbase_ed25519_secret = ${q(secret.toString("base64"))},`);
}
{
  // aws/src/credential-providers/from-login-credentials.ts dpopProof
  const pub = createPublicKey(createPrivateKey(KEYS.p256.sec1)).export({ format: "der", type: "spki" });
  const point = pub.indexOf(0x04, pub.length - 66);
  const header = jsonB64({
    alg: "ES256",
    typ: "dpop+jwt",
    jwk: {
      kty: "EC",
      crv: "P-256",
      x: pub.subarray(point + 1, point + 33).toString("base64url"),
      y: pub.subarray(point + 33, point + 65).toString("base64url"),
    },
  });
  const payload = jsonB64({
    jti: "00000000-0000-4000-8000-000000000000",
    htm: "POST",
    htu: "https://signin.aws.amazon.com/v1/token",
    iat: 1767225600,
  });
  const message = `${header}.${payload}`;
  w(`    dpop = { token = ${q(`${message}.${b64u(es256("p256", "P-256", message))}`)} },`);
}
{
  // acme/src/jose.ts signRequest (ES256 with the jwk; RS256 with a kid) and EAB
  const ecJwk = createPrivateKey(KEYS.p256.pkcs8).export({ format: "jwk" });
  const pubEc = { crv: ecJwk.crv, kty: "EC", x: ecJwk.x, y: ecJwk.y };
  const url = "https://acme.example/acme/new-account";
  const nonce = "oFvnlFP1wIhRlYS2jTaXbA";
  const p1 = jsonB64({ alg: "ES256", nonce, url, jwk: pubEc });
  const body = jsonB64({ termsOfServiceAgreed: true, contact: ["mailto:ops@example.com"] });
  w(`    acme_es256 = { protected = ${q(p1)}, payload = ${q(body)}, signature = ${q(b64u(es256("p256", "P-256", `${p1}.${body}`)))} },`);
  const kid = "https://acme.example/acme/acct/1";
  const p2 = jsonB64({ alg: "RS256", nonce, url: "https://acme.example/acme/order/1", kid });
  const sig2 = sign("sha256", Buffer.from(`${p2}.`), createPrivateKey(KEYS.rsa2048.pkcs8));
  w(`    acme_rs256_post_as_get = { protected = ${q(p2)}, payload = "", signature = ${q(b64u(sig2))} },`);
  const hmacKey = b64u(bytes(32));
  const p3 = jsonB64({ alg: "HS256", kid: "eab-kid", url });
  const pl3 = jsonB64(pubEc);
  const sig3 = createHmac("sha256", Buffer.from(hmacKey, "base64url")).update(`${p3}.${pl3}`).digest();
  w(`    acme_eab = { hmac_key = ${q(hmacKey)}, protected = ${q(p3)}, payload = ${q(pl3)}, signature = ${q(b64u(sig3))} },`);
}
w("  },");

// bigint arithmetic, BigInt as the reference
w("  bigint = {");
for (const [na, nb, nm] of [
  [1, 1, 1],
  [3, 2, 3],
  [32, 32, 32],
  [33, 31, 32],
  [64, 64, 32],
  [128, 128, 128],
  [256, 256, 128],
  [256, 128, 256],
  [512, 512, 512],
  [511, 300, 257],
]) {
  const a = bytes(na);
  const b = bytes(nb);
  const m = bytes(nm);
  m[nm - 1] |= 1; // odd
  m[0] |= 0x80;
  if (nm === 1 && m[0] < 3) m[0] = 3;
  const A = big(a);
  const Bv = big(b);
  const M = big(m);
  const e = bytes(Math.min(nm, 64));
  w(
    `    { a = ${q(hex(a))}, b = ${q(hex(b))}, m = ${q(hex(m))}, e = ${q(hex(e))}, product = ${q((A * Bv).toString(16))}, a_mod_m = ${q((A % M).toString(16))}, ab_mod_m = ${q(((A * Bv) % M).toString(16))}, pow = ${q(modpow(A, big(e), M).toString(16))} },`,
  );
}
w("  },");
w("}");
writeFileSync(out, lines.join("\n") + "\n");
console.log(`wrote ${out}`);
