-- Throughput of distilled.crypto under the current runtime, checked against the
-- published one-million-"a" digests (FIPS 180 / RFC 1321 test suites) so a fast wrong
-- answer cannot pass. Run through `verify/dl crypto-bench` (all three runtimes).
--
--   lua verify/lib/crypto_bench.lua        rex do verify/lib/crypto_bench.lua
--
-- Times are os.clock(): CPU time under lua/luajit, wall time under gopher-lua.
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

local crypto = require("distilled.crypto")
local hex = require("distilled.crypto.hex")

local rex_api = rawget(_G, "rex")
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)

local MILLION_A = {
  md5 = "7707d6ae4e027c70eea2a935c2296f21",
  sha1 = "34aa973cd4c4daa4f61eeb2bdbad27316534016f",
  sha256 = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  sha512 = "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb"
    .. "de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b",
  crc32 = 3693461436,
}

local data = string.rep("a", 1000000)
local failed = false
local lines = {}

local function report(line)
  lines[#lines + 1] = line
  print(line)
end

local function time(fn)
  local t0 = os.clock()
  local result = fn()
  return result, os.clock() - t0
end

-- first use builds the byte tables and compiles the generated code
local _, setup = time(function()
  for _, name in ipairs({ "md5", "sha1", "sha256", "sha512", "sha3_256" }) do
    crypto.digest(name, "")
  end
  return crypto.crc32("")
end)
report(string.format("%-8s setup (tables + generated code): %.3f s", runtime, setup))

for _, name in ipairs({ "md5", "sha1", "sha256", "sha512", "crc32" }) do
  local result, seconds = time(function()
    if name == "crc32" then
      return crypto.crc32(data)
    end
    return hex.encode(crypto.digest(name, data))
  end)
  local ok = result == MILLION_A[name]
  failed = failed or not ok
  report(
    string.format(
      "%-8s %-7s 1,000,000 bytes: %6.2f s  %6.2f MB/s  %s",
      runtime,
      name,
      seconds,
      1 / seconds,
      ok and "ok" or ("WRONG " .. tostring(result))
    )
  )
end

-- SHA3-256 (the Keccak sponge, as keccak256) on 100,000 bytes, digest from node:crypto
do
  local small = string.rep("a", 100000)
  local result, seconds = time(function()
    return hex.encode(crypto.sha3_256(small))
  end)
  local ok = result == "7c772c3f1ef6bb4320c0bf1597c3ddbdc4862bfd2ea2d9664208fd3ee17342c2"
  failed = failed or not ok
  report(
    string.format(
      "%-8s %-7s   100,000 bytes: %6.2f s  %6.2f MB/s  %s",
      runtime,
      "sha3",
      seconds,
      0.1 / seconds,
      ok and "ok" or ("WRONG " .. tostring(result))
    )
  )
end

-- small messages: what request signing does (SigV4 = 2 hashes + 5 HMACs per request)
local n = 200
local _, seconds = time(function()
  for i = 1, n do
    crypto.hmac_sha256("AWS4wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524" .. i)
  end
end)
report(string.format("%-8s hmac-sha256 short message: %.3f ms each", runtime, seconds / n * 1000))

do
  local sigv4 = require("distilled.sigv4")
  local m = 50
  local _, s = time(function()
    for i = 1, m do
      sigv4.sign({
        request = {
          method = "POST",
          url = "https://dynamodb.us-west-2.amazonaws.com/",
          headers = {
            ["content-type"] = "application/x-amz-json-1.0",
            ["x-amz-target"] = "DynamoDB_20120810.ListTables",
          },
          body = '{"Limit":' .. i .. "}",
        },
        credentials = {
          access_key_id = "AKIDEXAMPLE",
          secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        },
        region = "us-west-2",
        service = "dynamodb",
        now_epoch = 1700000000 + i,
      })
    end
  end)
  report(string.format("%-8s sigv4.sign small JSON request: %.2f ms each", runtime, s / m * 1000))
  local cache = {}
  local _, s2 = time(function()
    for i = 1, m do
      sigv4.sign({
        request = {
          method = "GET",
          url = "https://sqs.us-east-1.amazonaws.com/?Action=ListQueues&n=" .. i,
        },
        credentials = {
          access_key_id = "AKIDEXAMPLE",
          secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        },
        now_epoch = 1700000000 + i,
        key_cache = cache,
      })
    end
  end)
  report(string.format("%-8s sigv4.sign with key_cache: %.2f ms each", runtime, s2 / m * 1000))
end

if failed then
  error("crypto-bench: a digest is wrong")
end
