-- Public-key signing times under the current runtime, each result checked against the
-- node:crypto vector for the same key and message (spec/golden/crypto_pk/vectors.lua),
-- so a fast wrong answer cannot pass. Run through `verify/dl pk-bench` (all three
-- runtimes).
--
--   lua verify/lib/pk_bench.lua        rex do verify/lib/pk_bench.lua
--
-- Times are os.clock(): CPU time under lua/luajit, wall time under gopher-lua. "first"
-- is a fresh key (parsing, Montgomery set-up, code generation); "again" reuses it, as a
-- client that keeps its key object does.
local function script_root()
  local source = string.gsub(debug.getinfo(1, "S").source or "", "^@", "")
  local dir = string.match(source, "^(.*)/verify/lib/[^/]*$")
  return dir or "."
end
local ROOT = script_root()
package.path = ROOT
  .. "/lua/?.lua;"
  .. ROOT
  .. "/lua/?/init.lua;"
  .. ROOT
  .. "/?.lua;"
  .. package.path

local json = require("distilled.json")
local hex = require("distilled.crypto.hex")
local pem = require("distilled.crypto.pem")
local rsa = require("distilled.crypto.rsa")
local ecdsa = require("distilled.crypto.ecdsa")
local ed25519 = require("distilled.crypto.ed25519")
local vectors = require("spec.golden.crypto_pk.vectors")

local rex_api = rawget(_G, "rex")
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)

local f = assert(io.open(ROOT .. "/spec/golden/crypto_pk/keys.json", "rb"))
local KEYS = json.decode(f:read("*a"))
f:close()

local failed = false
local function check(ok, what)
  if not ok then
    failed = true
    print("FAIL " .. what)
  end
end

local function time(fn)
  local t0 = os.clock()
  local a, b = fn()
  return os.clock() - t0, a, b
end

local function find(list, pred)
  for _, v in ipairs(list) do
    if pred(v) then
      return v
    end
  end
end

local function row(name, first, again, verify)
  print(
    string.format(
      "%-8s %-22s first %7.3f s   again %7.3f s   verify %7.3f s",
      runtime,
      name,
      first,
      again,
      verify
    )
  )
end

for _, name in ipairs({ "rsa2048", "rsa3072", "rsa4096" }) do
  local v = find(vectors.rsa, function(x)
    return x.key == name and x.hash == "sha256"
  end)
  local msg = hex.decode(v.message)
  local first, sig = time(function()
    return rsa.sign(assert(pem.private_key(KEYS[name].pkcs1)), msg)
  end)
  check(sig and hex.encode(sig) == v.signature, name .. " signature")
  local k = assert(pem.private_key(KEYS[name].pkcs1))
  rsa.sign(k, msg)
  local again = time(function()
    return rsa.sign(k, msg)
  end)
  local pub = assert(pem.public_key(KEYS[name].spki))
  local verify, ok = time(function()
    return rsa.verify(pub, msg, sig)
  end)
  check(ok, name .. " verify")
  row("RS256 " .. name:sub(4) .. " (CRT)", first, again, verify)
end

for _, curve in ipairs({ { "p256", "ES256 P-256" }, { "secp256k1", "ES256K secp256k1" } }) do
  local v = find(vectors.ecdsa, function(x)
    return x.key == curve[1] and not x.low_s
  end)
  local msg = hex.decode(v.message)
  local first, sig = time(function()
    return ecdsa.sign(assert(pem.private_key(KEYS[curve[1]].sec1)), msg)
  end)
  check(sig and hex.encode(sig) == v.signature, curve[1] .. " signature")
  local k = assert(pem.private_key(KEYS[curve[1]].sec1))
  for _ = 1, ecdsa.COMB_AFTER do
    ecdsa.sign(k, msg) -- past the point where the fixed-base comb is built
  end
  local again = time(function()
    return ecdsa.sign(k, msg)
  end)
  local pub = assert(pem.public_key(KEYS[curve[1]].spki))
  local verify, ok = time(function()
    return ecdsa.verify(pub, msg, sig)
  end)
  check(ok, curve[1] .. " verify")
  row(curve[2], first, again, verify)
end

do
  local v = vectors.ed25519[3]
  local msg = hex.decode(v.message)
  local first, sig = time(function()
    return ed25519.sign(assert(pem.private_key(KEYS.ed25519.pkcs8)), msg)
  end)
  check(sig and hex.encode(sig) == v.signature, "ed25519 signature")
  local k = assert(pem.private_key(KEYS.ed25519.pkcs8))
  local again = time(function()
    return ed25519.sign(k, msg)
  end)
  local pub = assert(pem.public_key(KEYS.ed25519.spki))
  local verify, ok = time(function()
    return ed25519.verify(pub, msg, sig)
  end)
  check(ok, "ed25519 verify")
  row("EdDSA Ed25519", first, again, verify)
end

if failed then
  error("pk-bench: a result differs from node:crypto")
end
