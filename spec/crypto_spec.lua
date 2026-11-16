local t = require("spec.harness")
local crypto = require("distilled.crypto")
local secret = require("distilled.secret")
local hex = require("distilled.crypto.hex")
local base64 = require("distilled.crypto.base64")
local crc32 = require("distilled.crypto.crc32")
local sha2 = require("distilled.crypto.sha2")
local bytes = require("distilled.crypto.bytes")
local vectors = require("spec.golden.crypto.vectors")

local rep = string.rep

local function unhex(h)
  return (h:gsub("..", function(p)
    return string.char(tonumber(p, 16))
  end))
end

local function digest_hex(name, message)
  return hex.encode(crypto.digest(name, message))
end

t.describe("crypto: published test vectors", function()
  -- FIPS 180-4 examples (csrc.nist.gov "Examples with intermediate values") and
  -- RFC 1321 appendix A.5
  local ABC448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  local ABC896 = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
    .. "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"

  t.it("SHA-256 and SHA-224", function()
    t.eq(
      digest_hex("sha256", "abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    t.eq(
      digest_hex("sha256", ""),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    t.eq(
      digest_hex("sha256", ABC448),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )
    t.eq(digest_hex("sha224", "abc"), "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
    t.eq(digest_hex("sha224", ABC448), "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525")
  end)

  t.it("SHA-512 and SHA-384", function()
    t.eq(
      digest_hex("sha512", "abc"),
      "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
        .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    )
    t.eq(
      digest_hex("sha512", ABC896),
      "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
        .. "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
    )
    t.eq(
      digest_hex("sha384", "abc"),
      "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
        .. "8086072ba1e7cc2358baeca134c825a7"
    )
    t.eq(
      digest_hex("sha384", ABC896),
      "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712"
        .. "fcc7c71a557e2db966c3e9fa91746039"
    )
  end)

  t.it("SHA-1", function()
    t.eq(digest_hex("sha1", "abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    t.eq(digest_hex("sha1", ""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    t.eq(digest_hex("sha1", ABC448), "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
  end)

  t.it("MD5 (RFC 1321 test suite)", function()
    local suite = {
      { "", "d41d8cd98f00b204e9800998ecf8427e" },
      { "a", "0cc175b9c0f1b6a831c399e269772661" },
      { "abc", "900150983cd24fb0d6963f7d28e17f72" },
      { "message digest", "f96b697d7cb7938d525a2f31aaf161d0" },
      { "abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b" },
      {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
        "d174ab98d277d9f5a5611c2c9f419d9f",
      },
      { rep("1234567890", 8), "57edf4a22be3c955ac49da2e2107b67a" },
    }
    for _, c in ipairs(suite) do
      t.eq(digest_hex("md5", c[1]), c[2], c[1])
    end
  end)

  t.it("HMAC-SHA-2 (RFC 4231 test cases 1-7)", function()
    local AA131 = rep("\170", 131)
    local cases = {
      {
        rep("\11", 20),
        "Hi There",
        "896fb1128abbdf196832107cd49df33f47b4b1169912ba4f53684b22",
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6",
        "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde"
          .. "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854",
      },
      {
        "Jefe",
        "what do ya want for nothing?",
        "a30e01098bc6dbbf45690f3a7e9e6d0f8bbea2a39e6148008fd05e44",
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        "af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649",
        "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
          .. "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737",
      },
      {
        rep("\170", 20),
        rep("\221", 50),
        "7fb3cb3588c6c1f6ffa9694d7d6ad2649365b0c1f65d69d1ec8333ea",
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
        "88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b2a5ab39dc13814b94e3ab6e101a34f27",
        "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39"
          .. "bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb",
      },
      {
        unhex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
        rep("\205", 50),
        "6c11506874013cac6a2abc1bb382627cec6a90d86efc012de7afec5a",
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
        "3e8a69b7783c25851933ab6290af6ca77a9981480850009cc5577c6e1f573b4e6801dd23c4a7d679ccf8a386c674cffb",
        "b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3db"
          .. "a91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd",
      },
      -- test case 5 checks a truncation to 128 bits
      {
        rep("\12", 20),
        "Test With Truncation",
        "0e2aea68a90c8d37c988bcdb9fca6fa8",
        "a3b6167473100ee06e0c796c2955552b",
        "3abf34c3503b2a23a46efc619baef897",
        "415fad6271580a531d4179bc891d87a6",
      },
      {
        AA131,
        "Test Using Larger Than Block-Size Key - Hash Key First",
        "95e9a0db962095adaebe9b2d6f0dbce2d499f112f2d2b7273fa6870e",
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
        "4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c60c2ef6ab4030fe8296248df163f44952",
        "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352"
          .. "6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598",
      },
      {
        AA131,
        "This is a test using a larger than block-size key and a larger than block-size data."
          .. " The key needs to be hashed before being used by the HMAC algorithm.",
        "3a854166ac5d9f023f54d517d0b39dbd946770db9c2b95c9f6f565d1",
        "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
        "6617178e941f020d351e2f254e8fd32c602420feb0b8fb9adccebb82461e99c5a678cc31e799176d3860e6110c46523e",
        "e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944"
          .. "b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58",
      },
    }
    for i, c in ipairs(cases) do
      for k, name in ipairs({ "sha224", "sha256", "sha384", "sha512" }) do
        local expected = c[k + 2]
        local mac = hex.encode(crypto.hmac(name, c[1], c[2]))
        t.eq(mac:sub(1, #expected), expected, "case " .. i .. " " .. name)
      end
    end
  end)

  t.it("HMAC-MD5 and HMAC-SHA1 (RFC 2202)", function()
    local AA80 = rep("\170", 80)
    local cases = {
      { rep("\11", 16), rep("\11", 20), "Hi There" },
      { "Jefe", "Jefe", "what do ya want for nothing?" },
      { rep("\170", 16), rep("\170", 20), rep("\221", 50) },
      {
        unhex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
        unhex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
        rep("\205", 50),
      },
      { rep("\12", 16), rep("\12", 20), "Test With Truncation" },
      { AA80, AA80, "Test Using Larger Than Block-Size Key - Hash Key First" },
      { AA80, AA80, "Test Using Larger Than Block-Size Key and Larger Than One Block-Size Data" },
    }
    local md5 = {
      "9294727a3638bb1c13f48ef8158bfc9d",
      "750c783e6ab0b503eaa86e310a5db738",
      "56be34521d144c88dbb8c733f0e8b3f6",
      "697eaf0aca3a3aea3a75164746ffaa79",
      "56461ef2342edc00f9bab995690efd4c",
      "6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd",
      "6f630fad67cda0ee1fb1f562db3aa53e",
    }
    local sha1 = {
      "b617318655057264e28bc0b6fb378c8ef146be00",
      "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79",
      "125d7342b9ac11cd91a39af48aa17b4f63f175d3",
      "4c9007f4026250c6bc8414f9bf50c86c2d7235da",
      "4c1a03424b55e07fe7f27be1d58bb9324a9a5a04",
      "aa4ae5e15272d00e95705637ce8a3b55ed402112",
      "e8e99d0f45237d786d6bbaa7965c7808bbff1a91",
    }
    for i, c in ipairs(cases) do
      t.eq(hex.encode(crypto.hmac_md5(c[1], c[3])), md5[i], "md5 case " .. i)
      t.eq(hex.encode(crypto.hmac_sha1(c[2], c[3])), sha1[i], "sha1 case " .. i)
    end
  end)

  t.it("base64 (RFC 4648 section 10)", function()
    local cases = {
      { "", "" },
      { "f", "Zg==" },
      { "fo", "Zm8=" },
      { "foo", "Zm9v" },
      { "foob", "Zm9vYg==" },
      { "fooba", "Zm9vYmE=" },
      { "foobar", "Zm9vYmFy" },
    }
    for _, c in ipairs(cases) do
      t.eq(base64.encode(c[1]), c[2])
      t.eq(base64.decode(c[2]), c[1])
      t.eq(base64.url_encode(c[1]), (c[2]:gsub("=", "")))
      t.eq(base64.url_encode(c[1], true), c[2])
      t.eq(base64.url_decode(c[2]), c[1])
      t.eq(base64.url_decode((c[2]:gsub("=", ""))), c[1])
    end
  end)

  t.it("CRC-32 check values, and CRC-32C (RFC 3720 B.4)", function()
    t.eq(crc32.crc32("123456789"), 0xcbf43926)
    t.eq(crc32.crc32c("123456789"), 0xe3069283)
    t.eq(crc32.crc32c(rep("\0", 32)), 0x8a9136aa)
    t.eq(crc32.crc32c(rep("\255", 32)), 0x62a8ab43)
    local up, down = {}, {}
    for i = 0, 31 do
      up[#up + 1] = string.char(i)
      down[#down + 1] = string.char(31 - i)
    end
    t.eq(crc32.crc32c(table.concat(up)), 0x46dd794e)
    t.eq(crc32.crc32c(table.concat(down)), 0x113fdb5c)
    t.eq(crc32.crc32(""), 0)
  end)
end)

t.describe("crypto: random inputs against node:crypto (spec/golden/crypto/vectors.lua)", function()
  t.it("every digest, at every block-boundary length", function()
    t.truthy(#vectors.digests > 30)
    for _, v in ipairs(vectors.digests) do
      local input = unhex(v.input)
      for _, name in ipairs({ "md5", "sha1", "sha224", "sha256", "sha384", "sha512" }) do
        t.eq(digest_hex(name, input), v[name], name .. " of " .. #input .. " bytes")
      end
    end
  end)

  t.it("HMACs with keys shorter than, equal to and longer than the block", function()
    t.truthy(#vectors.hmacs > 60)
    for _, v in ipairs(vectors.hmacs) do
      local mac = crypto.hmac(v.hash, unhex(v.key), unhex(v.input))
      t.eq(hex.encode(mac), v.mac, v.hash .. " key " .. #v.key / 2 .. " bytes")
    end
  end)

  t.it("base64 and base64url of 0-40 random bytes, both ways", function()
    for _, v in ipairs(vectors.base64) do
      local input = unhex(v.input)
      t.eq(base64.encode(input), v.std)
      t.eq(base64.url_encode(input), v.url)
      t.eq(base64.decode(v.std), input)
      t.eq(base64.url_decode(v.url), input)
    end
  end)

  t.it("CRC-32 equals zlib.crc32, also when continued over pieces", function()
    for _, v in ipairs(vectors.crc32) do
      local input = unhex(v.input)
      t.eq(crc32.crc32(input), v.crc32)
      local cut = math.floor(#input / 3)
      t.eq(crc32.crc32(input:sub(cut + 1), crc32.crc32(input:sub(1, cut))), v.crc32)
    end
  end)
end)

t.describe("crypto: API", function()
  t.it("the shortcuts equal crypto.digest / crypto.hmac", function()
    for name in pairs(crypto.HASHES) do
      t.eq(crypto[name]("x"), crypto.digest(name, "x"), name)
      t.eq(crypto["hmac_" .. name]("k", "x"), crypto.hmac(name, "k", "x"), name)
      t.eq(#crypto[name](""), crypto.HASHES[name][3], name)
    end
  end)

  t.it("an HMAC key may be a secret, and gives the same MAC", function()
    t.eq(
      crypto.hmac_sha256(secret("Jefe"), "what do ya want for nothing?"),
      crypto.hmac_sha256("Jefe", "what do ya want for nothing?")
    )
  end)

  t.it("misuse raises: unknown hash, non-string message or key", function()
    t.raises(function()
      crypto.digest("sha3", "x")
    end, "unknown hash sha3")
    t.raises(function()
      crypto.sha256(42)
    end, "message must be a string")
    t.raises(function()
      crypto.hmac_sha256(nil, "x")
    end, "key must be a string or a secret")
    t.raises(function()
      crypto.hmac_sha256("k", { "x" })
    end, "message must be a string")
    t.raises(function()
      sha2.digest("sha1", "x")
    end, "unknown variant")
    t.raises(function()
      hex.encode(1)
    end, "expected a string")
    t.raises(function()
      crc32.crc32("x", -1)
    end, "crc must be an integer")
  end)

  t.it("binary input: every byte value, NULs and 0xFF", function()
    local all = {}
    for b = 0, 255 do
      all[#all + 1] = string.char(b)
    end
    local s = table.concat(all)
    -- node -e 'crypto.createHash("sha256").update(Buffer.from([...Array(256).keys()])).digest("hex")'
    t.eq(
      digest_hex("sha256", s),
      "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"
    )
    t.eq(digest_hex("md5", s), "e2c865db4162bed963bfaa9ef6ac18f0")
    t.eq(hex.decode(hex.encode(s)), s)
    t.eq(base64.decode(base64.encode(s)), s)
    t.eq(base64.url_decode(base64.url_encode(s)), s)
  end)

  t.it("crypto.equal compares whole strings", function()
    t.eq(crypto.equal("abc", "abc"), true)
    t.eq(crypto.equal("abc", "abd"), false)
    t.eq(crypto.equal("abc", "ab"), false)
    t.eq(crypto.equal("", ""), true)
  end)

  t.it("crc32.bytes is the big-endian checksum S3 base64-encodes", function()
    t.eq(hex.encode(crc32.bytes(0xcbf43926)), "cbf43926")
    t.eq(base64.encode(crc32.bytes(crc32.crc32("hello world"))), "DUoRhQ==")
  end)

  t.it("the generated compression functions are inspectable source", function()
    t.match(sha2.source("sha256"), "^local tb, L = %.%.%.")
    t.match(require("distilled.crypto.sha1").source(), "R5_1")
    t.match(require("distilled.crypto.md5").source(), "^local tb, L")
  end)

  t.it("bytes.linear shares the tables of a pure rotation across output bytes", function()
    local tables, plan = bytes.linear(8, { { "rotr", 28 }, { "rotr", 34 }, { "rotr", 39 } })
    t.truthy(#tables <= 8)
    t.eq(#plan[0], #plan[7])
    t.raises(function()
      bytes.linear(4, { { "rol", 1 } })
    end, "unknown term")
  end)
end)

t.describe("crypto: decoding errors are InvalidInput, never a raise", function()
  t.it("hex", function()
    t.fails_with("InvalidInput", hex.decode("abc"))
    local e = t.fails_with("InvalidInput", hex.decode("0g"))
    t.match(e.message, "position 2")
    t.eq(hex.decode(""), "")
    t.eq(hex.decode("0AfF"), "\10\255")
  end)

  t.it("base64: stray characters, whitespace, misplaced padding, impossible lengths", function()
    t.fails_with("InvalidInput", base64.decode("Zm9v Yg=="))
    t.fails_with("InvalidInput", base64.decode("Zm9vYg==\n"))
    t.fails_with("InvalidInput", base64.decode("Zm9=vYg="))
    t.fails_with("InvalidInput", base64.decode("Zm9vY==="))
    t.fails_with("InvalidInput", base64.decode("Zm9vY"))
    t.fails_with("InvalidInput", base64.decode("Zg="))
    t.fails_with("InvalidInput", base64.decode("-_8"))
    t.fails_with("InvalidInput", base64.url_decode("+/8"))
    local e = t.fails_with("InvalidInput", base64.decode("AAAA!AAA"))
    t.match(e.message, "position 5")
    t.eq(base64.url_decode("-_8"), "\251\255")
    t.eq(base64.decode("+/8="), "\251\255")
    t.eq(base64.decode(""), "")
  end)
end)
