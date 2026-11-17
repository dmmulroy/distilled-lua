local t = require("spec.harness")
local checksum = require("distilled.s3.checksum")
local payload = require("distilled.s3.payload")
local V = require("spec.golden.s3.presign")

local REQUIRED =
  { request_algorithm_member = "ChecksumAlgorithm", request_checksum_required = true }
local OPTIONAL = { request_algorithm_member = "ChecksumAlgorithm" }

local function request(body, headers)
  return { method = "POST", path = "/b?delete", query = {}, headers = headers or {}, body = body }
end

t.describe("s3.checksum: digests (Distilled's hashers, node for the rest)", function()
  for i, c in ipairs(V.checksum) do
    t.it("body " .. i .. " (" .. #c.body .. " bytes)", function()
      for _, alg in ipairs({ "md5", "crc32", "crc32c", "sha1", "sha256" }) do
        t.eq(checksum.value(alg, c.body), c[alg], alg)
      end
    end)
  end
end)

t.describe("s3.checksum.apply: middleware/checksum.ts rules", function()
  local body = V.checksum[3].body

  t.it("leaves a request alone without the trait or a body", function()
    local r = request(body)
    t.eq(checksum.apply(nil, r), r)
    local empty = request("")
    t.eq(checksum.apply(REQUIRED, empty), empty)
    local none = request(nil)
    t.eq(checksum.apply(REQUIRED, none), none)
  end)

  t.it("a required checksum without an algorithm is Content-MD5", function()
    local r = request(body, { ["Content-Type"] = "application/xml" })
    local out = checksum.apply(REQUIRED, r)
    t.eq(out.headers["Content-MD5"], V.checksum[3].md5)
    t.eq(out.headers["Content-Type"], "application/xml")
    t.eq(r.headers["Content-MD5"], nil, "input not modified")
    t.eq(out.body, body)
    t.eq(out.path, r.path)
  end)

  t.it("an optional checksum without an algorithm adds nothing (PutObject)", function()
    local r = request(body)
    t.eq(checksum.apply(OPTIONAL, r), r)
  end)

  t.it("the algorithm header picks x-amz-checksum-<alg>", function()
    for _, alg in ipairs({ "CRC32", "crc32c", "SHA1", "SHA256" }) do
      local r = request(body, { ["x-amz-sdk-checksum-algorithm"] = alg })
      local out = checksum.apply(OPTIONAL, r)
      local lower = alg:lower()
      t.eq(out.headers["x-amz-checksum-" .. lower], V.checksum[3][lower], alg)
      t.eq(out.headers["Content-MD5"], nil)
    end
  end)

  t.it("an algorithm we cannot compute adds nothing (as Distilled)", function()
    for _, alg in ipairs({ "CRC64NVME", "XXHASH64" }) do
      local r = request(body, { ["x-amz-sdk-checksum-algorithm"] = alg })
      t.eq(checksum.apply(REQUIRED, r), r)
    end
  end)

  t.it("the algorithm header is read only when the trait names a member", function()
    local r = request(body, { ["x-amz-sdk-checksum-algorithm"] = "CRC32" })
    local out = checksum.apply({ request_checksum_required = true }, r)
    t.eq(out.headers["Content-MD5"], V.checksum[3].md5)
    t.eq(out.headers["x-amz-checksum-crc32"], nil)
  end)

  t.it("keeps a checksum the caller gave, in either case", function()
    local r = request(body, { ["Content-MD5"] = "given" })
    t.eq(checksum.apply(REQUIRED, r), r)
    local r2 = request(body, { ["content-md5"] = "given" })
    t.eq(checksum.apply(REQUIRED, r2), r2)
    local r3 = request(body, {
      ["x-amz-sdk-checksum-algorithm"] = "CRC32",
      ["x-amz-checksum-crc32"] = "given",
    })
    t.eq(checksum.apply(OPTIONAL, r3), r3)
  end)

  t.it("header names", function()
    t.eq(checksum.header_name("md5"), "Content-MD5")
    t.eq(checksum.header_name("crc32"), "x-amz-checksum-crc32")
  end)
end)

t.describe("s3.payload.plan: x-amz-content-sha256 (protocol.ts toHttpRequest)", function()
  t.it("a plain request leaves the signer to decide", function()
    local h = { ["Content-Type"] = "application/xml" }
    local p = payload.plan({ headers = h, body = "<x/>", service_sdk_id = "S3" })
    t.eq(p.headers, h)
    t.eq(p.body, "<x/>")
    t.eq(p.hash_payload, false)
    t.eq(p.unsigned, false)
  end)

  t.it("a streaming input signs UNSIGNED-PAYLOAD without the body", function()
    local h = { ["Content-Length"] = "4" }
    local p =
      payload.plan({ headers = h, body = "data", streaming_input = true, service_sdk_id = "S3" })
    t.eq(p.headers["X-Amz-Content-Sha256"], "UNSIGNED-PAYLOAD")
    t.eq(p.headers["Content-Length"], "4")
    t.eq(h["X-Amz-Content-Sha256"], nil, "input not modified")
    t.eq(p.body, nil)
    t.eq(p.unsigned, true)
  end)

  t.it("services that rebuild the canonical request hash a streaming input", function()
    for _, sdk in ipairs({ "Glacier", "Lambda", "Bedrock Runtime", "IoT Data Plane" }) do
      local p =
        payload.plan({ headers = {}, body = "data", streaming_input = true, service_sdk_id = sdk })
      t.eq(p.unsigned, false, sdk)
      t.eq(p.body, "data", sdk)
    end
    t.eq(
      payload.plan({ headers = {}, body = "d", streaming_input = true, service_sdk_id = "Glacier" }).hash_payload,
      true
    )
    t.eq(
      payload.plan({ headers = {}, body = "d", streaming_input = true, service_sdk_id = "Lambda" }).hash_payload,
      false
    )
  end)

  t.it("an x-amz-checksum header with a body signs unsigned (EBS)", function()
    local p = payload.plan({
      headers = { ["x-amz-Checksum"] = "abc" },
      body = "blk",
      service_sdk_id = "EBS",
    })
    t.eq(p.unsigned, true)
    local q = payload.plan({ headers = { ["x-amz-Checksum"] = "abc" }, service_sdk_id = "EBS" })
    t.eq(q.unsigned, false)
  end)

  t.it("an x-amz-content-sha256 the request sets wins", function()
    local h = { ["x-amz-content-sha256"] = "STREAMING-UNSIGNED-PAYLOAD-TRAILER" }
    local p =
      payload.plan({ headers = h, body = "d", streaming_input = true, service_sdk_id = "S3" })
    t.eq(p.unsigned, false)
    t.eq(p.headers, h)
    local c = payload.plan({ headers = h, body = "d", service_sdk_id = "S3 Control" })
    t.eq(c.hash_payload, false)
  end)

  t.it("S3 Control and Glacier hash the payload", function()
    t.eq(
      payload.plan({ headers = {}, body = "<x/>", service_sdk_id = "S3 Control" }).hash_payload,
      true
    )
    t.eq(payload.plan({ headers = {}, service_sdk_id = "Glacier" }).hash_payload, true)
    t.eq(payload.plan({ headers = {}, body = "<x/>", service_sdk_id = "S3" }).hash_payload, false)
  end)
end)
