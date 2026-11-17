-- clients/s3 over a real transport against the local fixture server (`dl serve`, gated on
-- DL_SERVE_URL: run with `verify/dl test --http`). The client points `endpoint` at the
-- server, so requests are path-style (/<prefix>/<bucket>/<key>) as for MinIO or R2.
-- Checks what crosses the wire: SigV4 headers, exact binary bodies both ways, XML
-- bodies and their checksum, typed XML errors, a retried 503 SlowDown, ListObjectsV2
-- pages, and a presigned URL fetched without any signing on the client side.
local t = require("spec.harness")
local serve = require("verify.lib.serve")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local function pattern(n)
  return serve.pattern_bytes(n)
end

t.describe("s3 over HTTP (dl serve)", function()
  if not serve.url() then
    t.pending("DL_SERVE_URL is not set (run verify/dl test --http)")
    return
  end
  local S3 = require("s3")
  local s3 = require("distilled.s3")
  local crypto = require("distilled.crypto")
  local aws_credentials = require("distilled.aws.credentials")
  local host = require("verify.lib.canary").host()
  local srv = serve.client(host.transport)
  local PREFIX = "/s3http"
  local CREDS = {
    access_key_id = "AKIAIOSFODNN7EXAMPLE",
    secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region = "us-east-1",
  }
  local function client(extra)
    local o = {
      host = host,
      endpoint = serve.url() .. PREFIX,
      credentials = aws_credentials.static(CREDS),
      retry = { base_ms = 10, throttling_base_ms = 10, cap_ms = 20 },
    }
    for k, v in pairs(extra or {}) do
      o[k] = v
    end
    return S3.new(o)
  end
  local function requests_to(path)
    local out = {}
    for _, r in ipairs(srv.requests()) do
      if r.path == path then
        out[#out + 1] = r
      end
    end
    return out
  end

  t.it("PutObject sends the exact bytes, signed UNSIGNED-PAYLOAD", function()
    srv.reset()
    local body = pattern(1000)
    srv.script(PREFIX .. "/bkt/bin/data.bin", { { status = 200, headers = { ETag = '"e1"' } } })
    local out, err = client():put_object({
      Bucket = "bkt",
      Key = "bin/data.bin",
      Body = body,
      ContentType = "application/octet-stream",
      Metadata = { owner = "me" },
    })
    t.eq(err, nil, tostring(err and err.message))
    t.eq(out.ETag, '"e1"')
    local r = requests_to(PREFIX .. "/bkt/bin/data.bin")[1]
    t.eq(r.method, "PUT")
    t.eq(r.query, "x-id=PutObject")
    t.eq(crypto.base64.decode(r.body_b64), body)
    t.eq(r.headers["x-amz-content-sha256"], "UNSIGNED-PAYLOAD")
    t.eq(r.headers["x-amz-meta-owner"], "me")
    t.match(
      r.headers["authorization"],
      "^AWS4%-HMAC%-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/%d+/us%-east%-1/s3/aws4_request"
    )
    t.no_match(r.headers["authorization"], CREDS.secret_access_key, true)
  end)

  t.it("GetObject returns the whole body as a string, bytes exact", function()
    srv.reset()
    local body = pattern(70000)
    srv.script(PREFIX .. "/bkt/big.bin", {
      {
        status = 200,
        headers = { ["Content-Type"] = "application/octet-stream", ["x-amz-meta-a"] = "1" },
        body_b64 = crypto.base64.encode(body),
      },
    })
    local out, err = client():get_object({ Bucket = "bkt", Key = "big.bin" })
    t.eq(err, nil, tostring(err and err.message))
    t.eq(#out.Body, 70000)
    t.eq(out.Body == body, true, "bytes")
    t.eq(out.ContentLength, 70000)
    t.same(out.Metadata, { a = "1" })
  end)

  t.it("DeleteObjects sends XML with its Content-MD5", function()
    srv.reset()
    srv.script(PREFIX .. "/bkt", {
      {
        status = 200,
        body = '<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Deleted><Key>a</Key></Deleted></DeleteResult>',
      },
    })
    local out, err =
      client():delete_objects({ Bucket = "bkt", Delete = { Objects = { { Key = "a" } } } })
    t.eq(err, nil, tostring(err and err.message))
    t.eq(out.Deleted[1].Key, "a")
    local r = requests_to(PREFIX .. "/bkt")[1]
    t.eq(r.method, "POST")
    t.eq(r.query, "delete")
    t.eq(
      r.body,
      '<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Object><Key>a</Key></Object></Delete>'
    )
    t.eq(r.headers["content-md5"], crypto.base64.encode(crypto.md5(r.body)))
  end)

  t.it("a NoSuchKey XML error is the typed error", function()
    srv.reset()
    srv.script(PREFIX .. "/bkt/missing", {
      {
        status = 404,
        headers = { ["Content-Type"] = "application/xml" },
        body = "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>",
      },
    })
    local out, err = client():get_object({ Bucket = "bkt", Key = "missing" })
    t.eq(out, nil)
    t.eq(err.tag, "NoSuchKey")
    t.eq(err.message, "The specified key does not exist.")
    t.eq(err.status, 404)
  end)

  t.it("a 503 SlowDown is retried, then succeeds", function()
    srv.reset()
    srv.script(PREFIX .. "/bkt/k", {
      {
        status = 503,
        body = "<Error><Code>SlowDown</Code><Message>Reduce your request rate.</Message></Error>",
      },
      -- not valid base64: see the get-object-base64-text gap in s3_conform_spec
      { status = 200, body = "ok!" },
    })
    local out, err = client():get_object({ Bucket = "bkt", Key = "k" })
    t.eq(err, nil, tostring(err and err.message))
    t.eq(out.Body, "ok!")
    t.eq(#requests_to(PREFIX .. "/bkt/k"), 2)
  end)

  t.it("ListObjectsV2 pages follow NextContinuationToken", function()
    srv.reset()
    local function page(keys, next_token)
      local parts =
        { '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>bkt</Name>' }
      parts[#parts + 1] = "<IsTruncated>" .. (next_token and "true" or "false") .. "</IsTruncated>"
      if next_token then
        parts[#parts + 1] = "<NextContinuationToken>" .. next_token .. "</NextContinuationToken>"
      end
      for _, k in ipairs(keys) do
        parts[#parts + 1] = "<Contents><Key>" .. k .. "</Key><Size>1</Size></Contents>"
      end
      parts[#parts + 1] = "</ListBucketResult>"
      return table.concat(parts)
    end
    srv.script(PREFIX .. "/bkt", {
      { status = 200, body = page({ "a", "b" }, "t 1/+") },
      { status = 200, body = page({ "c" }) },
    })
    local keys = {}
    local it = client():list_objects_v2_pages({ Bucket = "bkt", MaxKeys = 2 })
    for p in it do
      for _, o in ipairs(p.Contents or {}) do
        keys[#keys + 1] = o.Key
      end
    end
    t.eq(it.err, nil)
    t.same(keys, { "a", "b", "c" })
    local rs = requests_to(PREFIX .. "/bkt")
    t.eq(#rs, 2)
    t.eq(rs[1].query, "max-keys=2&list-type=2")
    t.eq(rs[2].query, "max-keys=2&continuation-token=t%201%2F%2B&list-type=2")
  end)

  t.it("a presigned URL works with no signing on the caller's side", function()
    srv.reset()
    srv.script(PREFIX .. "/bkt/shared.txt", { { status = 200, body = "shared" } })
    local c = client()
    local u = assert(s3.presign_s3_url(c, { bucket = "bkt", key = "shared.txt", expires_in = 60 }))
    local res = assert(host.transport({ method = "GET", url = u, headers = {} }))
    t.eq(res.status, 200)
    t.eq(res.body, "shared")
    local r = requests_to(PREFIX .. "/bkt/shared.txt")[1]
    t.eq(r.headers["authorization"], nil)
    t.match(r.query, "X%-Amz%-Signature=%x+")
    t.match(r.query, "X-Amz-Expires=60", true)
  end)
end)
