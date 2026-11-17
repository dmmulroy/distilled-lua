-- Public-key crypto: bigint, RSA, ECDSA, Ed25519, PEM/DER, JWS/JWT.
--
-- Vectors: spec/golden/crypto_pk/published.lua (RFC 6979, 8032, 7515, 8037 and
-- tiny-secp256k1, extracted by verify/lib/pk_published.mjs) and vectors.lua (node:crypto
-- signatures and the tokens Distilled's packages mint, verify/lib/pk_vectors.mjs) for the
-- keys in keys.json.
local t = require("spec.harness")
local json = require("distilled.json")
local secret = require("distilled.secret")
local crypto = require("distilled.crypto")
local hex = require("distilled.crypto.hex")
local bigint = require("distilled.crypto.bigint")
local asn1 = require("distilled.crypto.asn1")
local pem = require("distilled.crypto.pem")
local rsa = require("distilled.crypto.rsa")
local ecdsa = require("distilled.crypto.ecdsa")
local ed25519 = require("distilled.crypto.ed25519")
local jws = require("distilled.crypto.jws")
local jwt = require("distilled.crypto.jwt")
local keys_mod = require("distilled.crypto.key")
local published = require("spec.golden.crypto_pk.published")
local vectors = require("spec.golden.crypto_pk.vectors")

local function read(path)
  local f = assert(io.open(t.root .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local KEYS = json.decode(read("spec/golden/crypto_pk/keys.json"))

local function unhex(h)
  return hex.decode(h)
end

-- parsed keys, cached across tests (parsing an EC key costs a scalar multiplication)
local parsed = {}
local function key(name, form)
  local id = name .. "/" .. form
  if not parsed[id] then
    local text = KEYS[name][form]
    local k, err
    if form == "spki" or form == "pkcs1_public" then
      k, err = pem.public_key(text)
    else
      k, err = pem.private_key(text)
    end
    parsed[id] = assert(k, err and err.message)
  end
  return parsed[id]
end

-- no error message, tostring or JSON of a key may carry key material
local function assert_no_secret(text, k)
  local priv = keys_mod.private(k)
  if priv and priv.d then
    local d = type(priv.d) == "table" and bigint.to_hex(priv.d) or hex.encode(priv.d)
    t.no_match(text, d:sub(1, 16), true)
  end
  if priv and priv.seed then
    t.no_match(text, hex.encode(priv.seed):sub(1, 16), true)
    t.no_match(text, jws.b64(priv.seed):sub(1, 12), true)
  end
end

---------------------------------------------------------------------------------------

t.describe("crypto_pk: bigint", function()
  t.it("matches BigInt for products, remainders and powers", function()
    for _, v in ipairs(vectors.bigint) do
      local a, b, m = bigint.from_hex(v.a), bigint.from_hex(v.b), bigint.from_hex(v.m)
      t.eq(bigint.to_hex(bigint.mul(a, b)), v.product)
      local ctx = bigint.mont(m)
      t.eq(bigint.to_hex(ctx:mod(a)), v.a_mod_m)
      t.eq(bigint.to_hex(ctx:mod(bigint.mul(a, b))), v.ab_mod_m)
      t.eq(bigint.to_hex(ctx:from(ctx:mul(ctx:to(a), ctx:to(b)))), v.ab_mod_m)
      t.eq(bigint.to_hex(ctx:from(ctx:pow(ctx:to(a), bigint.from_hex(v.e)))), v.pow)
    end
  end)

  t.it("generated products equal the generic loops (narrow and wide moduli)", function()
    local next_byte = 7
    local function rnd(n)
      local out = {}
      for i = 1, n do
        next_byte = (next_byte * 16807) % 2147483647
        out[i] = string.char(next_byte % 256)
      end
      return table.concat(out)
    end
    -- 2, 12, 47, 60 (last with locals), 62 and 100 limbs (tables)
    for _, nb in ipairs({ 5, 32, 128, 165, 170, 275 }) do
      local m = bigint.from_bytes("\255" .. rnd(nb - 2) .. "\1")
      local gen, loop = bigint.mont(m), bigint.mont(m, { generic = true })
      gen:compile()
      loop:compile()
      t.truthy(gen.source, "generated for " .. gen.k .. " limbs")
      t.eq(loop.source, nil)
      for i = 1, 6 do
        local a = gen:mod(bigint.from_bytes(rnd(nb)))
        local b = gen:mod(bigint.from_bytes(rnd(nb)))
        if i == 1 then -- the largest operands: m - 1
          a = bigint.sub(m, { 1 })
          b = bigint.copy(a)
        end
        t.eq(bigint.cmp(gen:mul(a, b), loop:mul(a, b)), 0)
        t.eq(bigint.cmp(gen:sqr(a), loop:sqr(a)), 0)
        t.eq(bigint.cmp(gen:sqr(a), loop:mul(a, a)), 0)
        -- in place, as pow uses them
        local c = bigint.copy(a)
        gen:mul(c, b, c)
        t.eq(bigint.cmp(c, loop:mul(a, b)), 0)
        gen:sqr(c, c)
        t.eq(bigint.cmp(c, loop:sqr(loop:mul(a, b))), 0)
      end
    end
  end)

  t.it("converts bytes, hex and numbers", function()
    t.eq(bigint.to_bytes(bigint.from_bytes("")), "")
    t.eq(bigint.to_hex(bigint.from_bytes("\0\0\1\0")), "100")
    t.eq(bigint.to_bytes(bigint.from_hex("0102"), 4), "\0\0\1\2")
    t.eq(bigint.to_bytes(bigint.from_hex("010203"), 2), nil)
    t.eq(bigint.to_number(bigint.from_number(9007199254740991)), 9007199254740991)
    t.eq(bigint.bits(bigint.from_hex("8000000000000000")), 64)
    t.eq(bigint.bits({}), 0)
    t.eq(bigint.to_hex(bigint.shr(bigint.from_hex("123456789abcdef"), 12)), "123456789abc")
    t.eq(bigint.cmp(bigint.from_hex("ff"), bigint.from_hex("100")), -1)
    t.eq(bigint.to_hex(bigint.sub(bigint.from_hex("1000000000000"), { 1 })), "ffffffffffff")
  end)

  t.it("modular add, sub, inverse at the edges", function()
    local p = bigint.from_hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
    local F = bigint.mont(p)
    local pm1 = F:to(bigint.sub(p, { 1 }))
    t.truthy(F:is_zero(F:add(pm1, F.one)))
    t.eq(bigint.to_hex(F:from(F:sub(F.zero, F.one))), bigint.to_hex(bigint.sub(p, { 1 })))
    local x = F:to(bigint.from_hex("1234567890abcdef"))
    t.truthy(F:eq(F:mul(x, F:inv(x)), F.one))
  end)

  t.it("raises on misuse", function()
    t.raises(function()
      bigint.mont(bigint.from_hex("10"))
    end, "odd")
    t.raises(function()
      bigint.sub({ 1 }, { 2 })
    end, "negative")
    t.raises(function()
      bigint.from_bytes(5)
    end, "expected a string")
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: PEM and DER", function()
  t.it("reads every key format node:crypto writes, to the same key", function()
    local k1, k8 = key("rsa2048", "pkcs1"), key("rsa2048", "pkcs8")
    t.eq(k1.kind, "rsa")
    t.eq(k1.bits, 2048)
    t.truthy(k1.private)
    t.eq(bigint.to_hex(k1.n), bigint.to_hex(k8.n))
    t.eq(bigint.to_hex(key("rsa2048", "spki").n), bigint.to_hex(k1.n))
    t.eq(bigint.to_hex(key("rsa2048", "pkcs1_public").n), bigint.to_hex(k1.n))
    t.falsy(key("rsa2048", "spki").private)
    for _, name in ipairs({ "p256", "secp256k1" }) do
      local sec1, p8, pub = key(name, "sec1"), key(name, "pkcs8"), key(name, "spki")
      t.eq(sec1.curve, name == "p256" and "P-256" or "secp256k1")
      t.eq(hex.encode(sec1.x), hex.encode(p8.x))
      t.eq(hex.encode(sec1.y), hex.encode(pub.y))
    end
    t.eq(hex.encode(key("ed25519", "pkcs8").public), hex.encode(key("ed25519", "spki").public))
  end)

  t.it("accepts DER, secrets, literal \\n and a leading EC PARAMETERS block", function()
    local text = KEYS.p256.sec1
    local der = pem.decode(text)[1].der
    t.eq(hex.encode(assert(pem.private_key(der)).x), hex.encode(key("p256", "sec1").x))
    local p8der = pem.decode(KEYS.rsa1024.pkcs8)[1].der
    t.eq(assert(pem.private_key(p8der)).bits, 1024)
    t.eq(assert(pem.private_key(pem.decode(KEYS.rsa1024.pkcs1)[1].der)).bits, 1024)
    t.eq(assert(pem.public_key(pem.decode(KEYS.ed25519.spki)[1].der)).kind, "ed25519")
    local escaped = text:gsub("\n", "\\n")
    t.eq(hex.encode(assert(pem.private_key(secret(escaped))).x), hex.encode(key("p256", "sec1").x))
    local params = "-----BEGIN EC PARAMETERS-----\nBggqhkjOPQMBBw==\n-----END EC PARAMETERS-----\n"
    t.eq(hex.encode(assert(pem.private_key(params .. text)).x), hex.encode(key("p256", "sec1").x))
    t.eq(pem.encode("PRIVATE KEY", pem.decode(KEYS.ed25519.pkcs8)[1].der), KEYS.ed25519.pkcs8)
  end)

  t.it("fails with InvalidInput on bad input, without quoting it", function()
    t.fails_with("InvalidInput", pem.private_key(KEYS.encrypted.pkcs8))
    t.fails_with("InvalidInput", pem.private_key("not a key"))
    t.fails_with(
      "InvalidInput",
      pem.private_key("-----BEGIN PRIVATE KEY-----\n%%%%\n-----END PRIVATE KEY-----")
    )
    t.fails_with("InvalidInput", pem.private_key("-----BEGIN PRIVATE KEY-----\nAAAA\n"))
    t.fails_with("InvalidInput", pem.private_key(KEYS.rsa2048.spki))
    t.fails_with("InvalidInput", pem.public_key(KEYS.rsa2048.pkcs1))
    t.fails_with(
      "InvalidInput",
      pem.private_key("-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----")
    )
    -- a truncated key: every prefix of the DER fails cleanly
    local der = pem.decode(KEYS.p256.pkcs8)[1].der
    for cut = 1, #der - 1, 7 do
      local k, err = pem.private_key(der:sub(1, cut))
      t.eq(k, nil)
      t.eq(err.tag, "InvalidInput")
      assert_no_secret(err.message, key("p256", "pkcs8"))
    end
    -- an RSA key whose primes do not match its modulus
    local f = {}
    local k = key("rsa1024", "pkcs1")
    local priv = keys_mod.private(k)
    for name, v in pairs(priv) do
      f[name] = v
    end
    f.n, f.e = k.n, k.e
    f.p = bigint.add(f.p, { 2 })
    t.fails_with("InvalidInput", rsa.private_key(f))
    t.raises(function()
      pem.private_key(42)
    end, "expected PEM")
  end)

  t.it("DER integers, OIDs and lengths", function()
    local seq = asn1.sequence(
      asn1.encode_integer(bigint.from_hex("80")),
      asn1.encode_oid("1.2.840.10045.3.1.7")
    )
    t.eq(hex.encode(seq), "300e020200800608" .. "2a8648ce3d030107")
    local items = asn1.items(asn1.read_all(seq).value)
    t.eq(bigint.to_hex(assert(asn1.integer(items[1]))), "80")
    t.eq(asn1.oid(items[2]), "1.2.840.10045.3.1.7")
    t.fails_with("InvalidInput", asn1.integer({ tag = 2, value = "\128" }))
    t.fails_with("InvalidInput", asn1.read("\48\128\0\0"))
    t.fails_with("InvalidInput", asn1.read("\48\5\1"))
    t.fails_with("InvalidInput", asn1.read_all("\5\0\0"))
    local long = asn1.encode(asn1.OCTET_STRING, string.rep("x", 300))
    t.eq(hex.encode(long:sub(1, 4)), "0482012c")
    t.eq(#assert(asn1.read_all(long)).value, 300)
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: RSA", function()
  t.it("RFC 7515 A.2: the RS256 example JWS, byte for byte", function()
    local v = published.rfc7515.rs256
    local k = assert(jws.key_from_jwk(v.jwk))
    t.eq(k.bits, 2048)
    local h, p = v.jws:match("^([^.]+)%.([^.]+)%.")
    local sig = assert(jws.sign_bytes("RS256", k, h .. "." .. p))
    t.eq(h .. "." .. p .. "." .. jws.b64(sig), v.jws)
    t.truthy(jws.verify(v.jws, keys_mod.public(k)))
  end)

  t.it("signs byte for byte as node:crypto (1024 to 4096 bits, SHA-256/384/512)", function()
    local signed = {}
    for _, v in ipairs(vectors.rsa) do
      -- every key size and hash once; all of them for 1024 bits
      local id = v.key .. v.hash
      if v.key == "rsa1024" or not signed[id] then
        signed[id] = true
        local s = assert(rsa.sign(key(v.key, "pkcs1"), unhex(v.message), v.hash))
        t.eq(hex.encode(s), v.signature, v.key .. " " .. v.hash)
      end
    end
  end)

  t.it("signs without CRT parameters (a JWK with only n, e, d)", function()
    local k = key("rsa1024", "pkcs8")
    local priv = keys_mod.private(k)
    local bare = assert(rsa.private_key({ n = k.n, e = k.e, d = priv.d }))
    local v = vectors.rsa[1]
    t.eq(hex.encode(assert(rsa.sign(bare, unhex(v.message)))), v.signature)
  end)

  t.it("verifies node:crypto's signatures and rejects altered ones", function()
    for i, v in ipairs(vectors.rsa) do
      local pub = key(v.key, "spki")
      local msg, sig = unhex(v.message), unhex(v.signature)
      t.truthy(rsa.verify(pub, msg, sig, v.hash))
      if i % 3 == 1 or v.key ~= "rsa1024" then
        t.falsy(rsa.verify(pub, msg .. "x", sig, v.hash))
        local flipped = string.char((sig:byte(10) + 1) % 256)
        t.falsy(rsa.verify(pub, msg, sig:sub(1, 9) .. flipped .. sig:sub(11), v.hash))
        t.falsy(rsa.verify(pub, msg, sig:sub(2), v.hash))
        t.falsy(rsa.verify(pub, msg, string.rep("\255", #sig), v.hash))
      end
    end
    local v = vectors.rsa[1]
    t.falsy(rsa.verify(key(v.key, "spki"), unhex(v.message), unhex(v.signature), "sha512"))
  end)

  t.it("fails or raises on misuse", function()
    t.fails_with("InvalidInput", rsa.sign(key("rsa1024", "spki"), "m"))
    t.raises(function()
      rsa.sign(key("p256", "sec1"), "m")
    end, "expected an RSA key")
    t.raises(function()
      rsa.sign(key("rsa1024", "pkcs1"), "m", "md5")
    end, "unsupported hash")
    t.fails_with("InvalidInput", rsa.public_key({ n = bigint.from_hex("ff01"), e = { 3 } }))
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: ECDSA", function()
  t.it("RFC 6979 A.2.5: P-256 deterministic signatures, every hash", function()
    local v = published.rfc6979_p256
    local k = assert(ecdsa.private_key("P-256", unhex(v.x)))
    t.eq(hex.encode(k.x), v.ux)
    t.eq(hex.encode(k.y), v.uy)
    for _, s in ipairs(v.signatures) do
      local sig = assert(ecdsa.sign(k, s.message, { hash = s.hash }))
      t.eq(hex.encode(sig), s.r .. s.s, s.hash .. " " .. s.message)
      t.truthy(ecdsa.verify(k, s.message, sig, { hash = s.hash }))
    end
  end)

  t.it("tiny-secp256k1: RFC 6979 secp256k1 with low S, recovery ids and recovery", function()
    for i, v in ipairs(published.secp256k1) do
      local k = assert(ecdsa.private_key("secp256k1", unhex(v.d)))
      local sig, recid = ecdsa.sign_digest(k, unhex(v.m), { low_s = true })
      t.eq(hex.encode(sig), v.signature)
      t.eq(recid, v.recovery_id)
      -- recovery and verification cost two scalar multiplications each (slow in Rex);
      -- every recovery id the vectors contain is among the first 8
      if i <= 8 then
        local q = assert(ecdsa.recover("secp256k1", unhex(v.m), sig, recid))
        t.eq(hex.encode(q.x), hex.encode(k.x))
        t.eq(hex.encode(q.y), hex.encode(k.y))
        t.truthy(ecdsa.verify_digest(q, unhex(v.m), sig))
      end
    end
  end)

  t.it("signs as node:crypto verifies (P-256, secp256k1; raw and DER)", function()
    for i, v in ipairs(vectors.ecdsa) do
      local k = key(v.key, "pkcs8")
      local msg = unhex(v.message)
      local sig, recid = ecdsa.sign(k, msg, { low_s = v.low_s })
      t.eq(hex.encode(sig), v.signature)
      t.eq(recid, v.recovery_id)
      t.eq(hex.encode((ecdsa.sign(k, msg, { low_s = v.low_s, format = "der" }))), v.der)
      t.eq(hex.encode(assert(ecdsa.der_to_raw(unhex(v.der)))), v.signature)
      t.eq(hex.encode(ecdsa.raw_to_der(sig)), v.der)
      local pub = key(v.key, "spki")
      t.truthy(ecdsa.verify(pub, msg, sig))
      if i % 4 == 1 then -- two per curve
        t.truthy(ecdsa.verify(pub, msg, unhex(v.der), { format = "der" }))
        t.falsy(ecdsa.verify(pub, msg .. "x", sig))
        t.falsy(ecdsa.verify(pub, msg, sig:sub(1, 63) .. string.char((sig:byte(64) + 1) % 256)))
      end
    end
  end)

  t.it("RFC 7515 A.3: verifies the ES256 example JWS", function()
    local v = published.rfc7515.es256
    local k = assert(jws.key_from_jwk(v.jwk))
    local header, payload = jws.verify(v.jws, keys_mod.public(k))
    t.eq(header.alg, "ES256")
    t.match(payload, '"iss":"joe"', true)
    t.fails_with("InvalidInput", jws.verify(v.jws:sub(1, -3) .. "AA", k))
  end)

  t.it("points: compressed, off-curve, out of range, mismatched", function()
    local k = key("secp256k1", "sec1")
    local c = ecdsa.point_bytes(k, true)
    t.eq(#c, 33)
    t.eq(hex.encode(assert(ecdsa.public_key("secp256k1", c)).y), hex.encode(k.y))
    local p = key("p256", "sec1")
    t.eq(
      hex.encode(assert(ecdsa.public_key("P-256", ecdsa.point_bytes(p, true))).y),
      hex.encode(p.y)
    )
    local bad_y = "\4" .. k.x .. k.x
    t.fails_with("InvalidInput", ecdsa.public_key("secp256k1", bad_y))
    t.fails_with("InvalidInput", ecdsa.public_key("secp256k1", "\4" .. string.rep("\255", 64)))
    t.fails_with("InvalidInput", ecdsa.public_key("P-256", "\5abc"))
    t.fails_with("InvalidInput", ecdsa.private_key("P-256", string.rep("\255", 32)))
    t.fails_with("InvalidInput", ecdsa.private_key("P-256", string.rep("\0", 32)))
    t.fails_with("InvalidInput", ecdsa.private_key("P-256", "\1", ecdsa.point_bytes(p)))
    t.fails_with("InvalidInput", ecdsa.der_to_raw("\48\0"))
    t.falsy(ecdsa.verify(p, "m", string.rep("\0", 64)))
    t.falsy(ecdsa.verify(p, "m", "short"))
    t.fails_with(
      "InvalidInput",
      ecdsa.recover("secp256k1", string.rep("\1", 32), string.rep("\0", 64), 0)
    )
    t.fails_with("InvalidInput", ecdsa.sign(key("p256", "spki"), "m"))
    t.raises(function()
      ecdsa.private_key("P-384", "x")
    end, "unsupported curve")
    t.raises(function()
      ecdsa.recover("secp256k1", "d", string.rep("\1", 64), 4)
    end, "recovery_id")
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: Ed25519", function()
  t.it("RFC 8032 7.1: TEST 1, 2, 3, 1024 and SHA(abc)", function()
    for _, v in ipairs(published.rfc8032) do
      local k = assert(ed25519.private_key(unhex(v.secret)))
      t.eq(hex.encode(k.public), v.public, v.name)
      local sig = assert(ed25519.sign(k, unhex(v.message)))
      t.eq(hex.encode(sig), v.signature, v.name)
      t.truthy(ed25519.verify(assert(ed25519.public_key(unhex(v.public))), unhex(v.message), sig))
    end
    t.eq(#unhex(published.rfc8032[4].message), 1023)
  end)

  t.it("RFC 8037 A: the JWK, its thumbprint and the EdDSA JWS", function()
    local v = published.rfc8037
    local k = assert(jws.key_from_jwk(v.jwk))
    t.eq(assert(jws.json(jws.public_jwk(k))), v.canonical)
    t.eq(jws.thumbprint(k), v.thumbprint)
    t.eq(assert(jws.compact({ key = k, payload = v.payload })), v.jws)
    local header, payload = jws.verify(v.jws, keys_mod.public(k))
    t.eq(header.alg, "EdDSA")
    t.eq(payload, v.payload)
  end)

  t.it("signs byte for byte as node:crypto and verifies its signatures", function()
    local k, pub = key("ed25519", "pkcs8"), key("ed25519", "spki")
    for _, v in ipairs(vectors.ed25519) do
      local msg = unhex(v.message)
      t.eq(hex.encode(assert(ed25519.sign(k, msg))), v.signature)
      t.truthy(ed25519.verify(pub, msg, unhex(v.signature)))
      t.falsy(ed25519.verify(pub, msg .. "x", unhex(v.signature)))
    end
  end)

  t.it("rejects S >= L, bad points and bad lengths", function()
    local v = published.rfc8032[1]
    local pub = assert(ed25519.public_key(unhex(v.public)))
    local sig = unhex(v.signature)
    -- S + L encodes the same scalar mod L but must be refused (malleability)
    local S = bigint.from_bytes(sig:sub(33):reverse())
    local L = bigint.from_hex("1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")
    local big_s = bigint.to_bytes(bigint.add(S, L), 32):reverse()
    t.falsy(ed25519.verify(pub, "", sig:sub(1, 32) .. big_s))
    t.falsy(ed25519.verify(pub, "", sig:sub(1, 63)))
    t.falsy(ed25519.verify(pub, "", string.rep("\255", 32) .. sig:sub(33)))
    t.fails_with("InvalidInput", ed25519.public_key(string.rep("\255", 32)))
    t.fails_with("InvalidInput", ed25519.private_key("short"))
    t.fails_with("InvalidInput", ed25519.sign(pub, "m"))
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: tokens as Distilled's packages mint them", function()
  local tokens = vectors.tokens

  t.it("GitHub App JWT (RS256, PKCS #1 key)", function()
    local v = tokens.github_app
    local token = assert(jwt.encode({
      key = key("rsa2048", "pkcs1"),
      claims = jws.object("iss", v.app_id, "iat", v.iat, "exp", v.iat + 600),
    }))
    t.eq(token, v.token)
    -- PEM text (and a secret holding it) works as the key too
    t.eq(
      jwt.encode({
        key = secret(KEYS.rsa2048.pkcs1),
        claims = jws.object("iss", v.app_id, "iat", v.iat, "exp", v.iat + 600),
      }),
      v.token
    )
  end)

  t.it("GCP service-account assertion (RS256, PKCS #8 key, kid)", function()
    local v = tokens.gcp
    local token = assert(jwt.encode({
      key = key("rsa2048", "pkcs8"),
      header = jws.object("typ", "JWT", "kid", "abc123"),
      claims = jws.object(
        "iss",
        "svc@project.iam.gserviceaccount.com",
        "scope",
        "https://www.googleapis.com/auth/cloud-platform",
        "aud",
        "https://oauth2.googleapis.com/token",
        "iat",
        v.iat,
        "exp",
        v.iat + 3600
      ),
    }))
    t.eq(token, v.token)
  end)

  local function coinbase(k)
    local id = "organizations/org-id/apiKeys/key-id"
    local now = 1767225600
    return jwt.encode({
      key = k,
      header = jws.object("kid", id, "typ", "JWT", "nonce", "0123456789abcdef0123456789abcdef"),
      claims = jws.object(
        "sub",
        id,
        "iss",
        "cdp",
        "aud",
        { "cdp_service" },
        "nbf",
        now,
        "exp",
        now + 120,
        "uri",
        "GET api.cdp.coinbase.com/platform/v2/evm/accounts"
      ),
    })
  end

  t.it("Coinbase CDP JWT: ES256 from an EC PEM, EdDSA from the base64 secret", function()
    t.eq(assert(coinbase(key("p256", "sec1"))), tokens.coinbase_es256.token)
    local raw = assert(crypto.base64.decode(tokens.coinbase_ed25519_secret))
    t.eq(#raw, 64)
    local k = assert(ed25519.private_key(raw:sub(1, 32)))
    t.eq(k.public, raw:sub(33))
    t.eq(assert(coinbase(k)), tokens.coinbase_eddsa.token)
  end)

  t.it("AWS login DPoP proof (ES256, jwk header)", function()
    local k = key("p256", "sec1")
    local token = assert(jwt.encode({
      key = k,
      header = jws.object(
        "typ",
        "dpop+jwt",
        "jwk",
        jws.object("kty", "EC", "crv", "P-256", "x", jws.b64(k.x), "y", jws.b64(k.y))
      ),
      claims = jws.object(
        "jti",
        "00000000-0000-4000-8000-000000000000",
        "htm",
        "POST",
        "htu",
        "https://signin.aws.amazon.com/v1/token",
        "iat",
        1767225600
      ),
    }))
    t.eq(token, tokens.dpop.token)
  end)

  t.it("ACME: ES256 with the jwk, RS256 POST-as-GET with a kid, HS256 EAB", function()
    local ec = key("p256", "pkcs8")
    local url = "https://acme.example/acme/new-account"
    local nonce = "oFvnlFP1wIhRlYS2jTaXbA"
    local signed = assert(jws.flattened({
      key = ec,
      header = jws.object("nonce", nonce, "url", url, "jwk", jws.public_jwk(ec)),
      payload = jws.object("termsOfServiceAgreed", true, "contact", { "mailto:ops@example.com" }),
    }))
    t.same(signed, tokens.acme_es256)
    local get = assert(jws.flattened({
      key = key("rsa2048", "pkcs8"),
      header = jws.object(
        "nonce",
        nonce,
        "url",
        "https://acme.example/acme/order/1",
        "kid",
        "https://acme.example/acme/acct/1"
      ),
    }))
    t.same(get, tokens.acme_rs256_post_as_get)
    local eab = tokens.acme_eab
    local bound = assert(jws.flattened({
      key = secret(assert(jws.b64_decode(eab.hmac_key))),
      alg = "HS256",
      header = jws.object("kid", "eab-kid", "url", url),
      payload = jws.public_jwk(ec),
    }))
    t.same(bound, { protected = eab.protected, payload = eab.payload, signature = eab.signature })
  end)
end)

---------------------------------------------------------------------------------------

t.describe("crypto_pk: JWS, JWT and JWK", function()
  t.it("JWKs and thumbprints agree with node:crypto", function()
    for name, v in pairs(vectors.public) do
      local from_node = assert(jws.key_from_jwk(v.jwk))
      t.eq(jws.thumbprint(from_node), v.thumbprint, name)
      local form = name == "rsa2048" and "pkcs8" or "pkcs8"
      local k = key(name, form)
      t.eq(jws.thumbprint(k), v.thumbprint, name)
      -- the private JWK node exports imports to the same key and exports back equal
      local priv = assert(jws.key_from_jwk(secret(v.private_jwk)))
      t.truthy(priv.private)
      t.same(
        json.decode(assert(jws.json(jws.jwk(priv, { private = true })))),
        json.decode(v.private_jwk)
      )
      t.same(json.decode(assert(jws.json(jws.jwk(k)))), json.decode(v.jwk))
    end
  end)

  t.it("JWK errors", function()
    t.fails_with("InvalidInput", jws.key_from_jwk('{"kty":"EC","crv":"P-384","x":"AA","y":"AA"}'))
    t.fails_with("InvalidInput", jws.key_from_jwk('{"kty":"RSA","n":"!!","e":"AQAB"}'))
    t.fails_with("InvalidInput", jws.key_from_jwk('{"kty":"RSA","e":"AQAB"}'))
    t.fails_with("InvalidInput", jws.key_from_jwk('{"kty":"oct","k":"AA"}'))
    t.fails_with("InvalidInput", jws.key_from_jwk("not json"))
    local v = published.rfc8037
    local jwk = json.decode(v.jwk)
    jwk.x = published.rfc8032[2].public and jws.b64(unhex(published.rfc8032[2].public))
    t.fails_with("InvalidInput", jws.key_from_jwk(jwk))
  end)

  t.it("jwt.verify checks signature, alg, exp and nbf", function()
    local k = key("ed25519", "pkcs8")
    local token = assert(jwt.encode({ key = k, claims = { sub = "x", exp = 1000, nbf = 900 } }))
    local claims, header = jwt.verify(token, key("ed25519", "spki"), { now = 950 })
    t.eq(claims.sub, "x")
    t.eq(header.typ, "JWT")
    t.fails_with("InvalidInput", jwt.verify(token, key("ed25519", "spki"), { now = 1001 }))
    t.truthy(jwt.verify(token, key("ed25519", "spki"), { now = 1001, leeway = 5 }))
    t.fails_with("InvalidInput", jwt.verify(token, key("ed25519", "spki"), { now = 800 }))
    t.fails_with("InvalidInput", jwt.verify(token, key("p256", "spki"), { now = 950 }))
    t.fails_with(
      "InvalidInput",
      jwt.verify(token, key("ed25519", "spki"), { now = 950, algorithms = { "RS256" } })
    )
    local claims2 = jwt.decode(token)
    t.eq(claims2.exp, 1000)
    t.fails_with("InvalidInput", jwt.decode("a.b"))
    t.fails_with("InvalidInput", jwt.decode("e30.e30.%%"))
    t.fails_with("InvalidInput", jwt.decode(jws.b64("[]") .. ".e30."))
    -- "none" and HS256 tokens are not accepted with a public key
    local none = jws.b64('{"alg":"none"}') .. "." .. jws.b64('{"sub":"x"}') .. "."
    t.fails_with("InvalidInput", jwt.verify(none, key("ed25519", "spki")))
    local hs = assert(jwt.encode({ key = "shared", alg = "HS256", claims = { a = 1 } }))
    t.fails_with("InvalidInput", jwt.verify(hs, key("ed25519", "spki")))
    t.eq(jwt.verify(hs, secret("shared"), { algorithms = { "HS256" } }).a, 1)
    t.fails_with("InvalidInput", jwt.verify(hs, secret("shared")))
    -- algorithm confusion: an HS256 token keyed with a public key's PEM text
    local pem_text = KEYS.ed25519.spki
    local forged = assert(jwt.encode({ key = pem_text, alg = "HS256", claims = { a = 1 } }))
    t.fails_with("InvalidInput", jwt.verify(forged, pem_text))
    t.fails_with("InvalidInput", jwt.verify(forged, key("ed25519", "spki")))
  end)

  t.it("ordered JSON: order kept, nils dropped, nesting bounded", function()
    t.eq(
      assert(jws.json(jws.object("b", 1, "a", nil, "c", { 1, 2 }, "d", { z = 1, y = "x" }))),
      '{"b":1,"c":[1,2],"d":{"y":"x","z":1}}'
    )
    t.eq(assert(jws.json(json.array({}))), "[]")
    t.eq(assert(jws.json({})), "{}")
    t.eq(assert(jws.json("é\n")), '"é\\n"')
    local deep = 1
    for _ = 1, 40 do
      deep = { deep }
    end
    t.fails_with("InvalidInput", jws.json(deep))
    t.fails_with("InvalidInput", jws.json({ s = secret("x") }))
    t.raises(function()
      jws.compact({ key = key("p256", "sec1"), header = { alg = "none" }, payload = "x" })
    end, "alg is set")
    t.raises(function()
      jws.object("a")
    end, "pairs")
  end)

  t.it("alg and key must agree", function()
    t.fails_with(
      "InvalidInput",
      jws.compact({ key = key("p256", "sec1"), alg = "RS256", payload = "x" })
    )
    t.fails_with(
      "InvalidInput",
      jws.compact({ key = key("p256", "sec1"), alg = "ES256K", payload = "x" })
    )
    local es256k = assert(jws.compact({ key = key("secp256k1", "sec1"), payload = "x" }))
    t.eq(jws.decode(es256k).header.alg, "ES256K")
    t.truthy(jws.verify(es256k, key("secp256k1", "spki")))
    t.fails_with("InvalidInput", jws.compact({ key = "not pem", payload = "x" }))
  end)

  t.it("keys print and encode without their private parts", function()
    for _, id in ipairs({ { "rsa1024", "pkcs1" }, { "p256", "sec1" }, { "ed25519", "pkcs8" } }) do
      local k = key(id[1], id[2])
      local text = tostring(k)
      t.match(text, "private key", true)
      assert_no_secret(text, k)
      assert_no_secret(assert(json.encode(k)), k)
      for name in pairs(k) do
        t.ne(name, "d")
        t.ne(name, "seed")
      end
    end
    t.eq(tostring(key("rsa2048", "spki")), "<rsa public key, 2048 bits>")
    t.eq(tostring(key("p256", "spki")), "<ec P-256 public key>")
  end)
end)
