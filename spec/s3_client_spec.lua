-- distilled.s3: the presign helpers over a client (its credentials, region, endpoint and
-- host), on a small client class with the options an AWS client has and a protocol whose
-- encode returns a request signed in its headers, as aws/protocol.lua's does.
local t = require("spec.harness")
local Client = require("distilled.client")
local presign = require("distilled.s3.presign")
local s3 = require("distilled.s3")
local secret = require("distilled.secret")
local sigv4 = require("distilled.sigv4")
local testing = require("distilled.testing")
local V = require("spec.golden.s3.presign")

local CREDS = {
  access_key_id = V.access_key_id,
  secret_access_key = V.secret_access_key,
  region = "us-east-1",
}

-- the protocol: encode builds GET <endpoint or https://b.s3.<region>.amazonaws.com>/k
-- with the input's headers, signed in headers (service "s3")
local function fake_protocol(log)
  local protocol = {}
  function protocol.call()
    return nil, { tag = "SdkError", message = "not used" }
  end
  function protocol.encode(ctx, op, input, opts)
    log[#log + 1] = { ctx = ctx, op = op, input = input, opts = opts }
    local creds = secret.unwrap(opts.credentials)
    local region = opts.region or creds.region
    local base = opts.endpoint or ("https://b.s3." .. region .. ".amazonaws.com")
    local headers = {}
    for k, v in pairs(input.headers or {}) do
      headers[k] = v
    end
    return sigv4.sign({
      request = {
        method = op.method,
        url = base .. "/k" .. (input.query or ""),
        headers = headers,
        body = input.body,
      },
      credentials = creds,
      region = region,
      service = input.service or "s3",
      now_epoch = ctx.host.epoch(),
    })
  end
  return protocol
end

local log = {}
local Fake = Client.define({
  name = "FakeS3",
  service = {
    name = "FakeS3",
    shapes = {},
    ops = {
      get_thing = { name = "GetThing", method = "GET" },
      put_thing = { name = "PutThing", method = "PUT" },
    },
  },
  protocol = fake_protocol(log),
  options = {
    region = { type = "string" },
    endpoint = { type = "string" },
    credentials = { secret = true },
  },
})

local function client(extra)
  local o = {
    host = testing.host({ epoch = 1369353600 }),
    credentials = function()
      return CREDS
    end,
  }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return Fake.new(o)
end

t.describe("distilled.s3: presign helpers with a client", function()
  t.it("presign_s3_url uses the client's credentials, region and clock", function()
    local c = client()
    local got = assert(s3.presign_s3_url(c, { bucket = "examplebucket", key = "dir/a b.txt" }))
    t.eq(got, V.s3_url[8].expected.value) -- "no version"
  end)

  t.it("a call's own options win over the client's", function()
    local c = client({ region = "eu-west-1" })
    local own = assert(s3.presign_s3_url(c, {
      bucket = "examplebucket",
      key = "a.txt",
      region = "us-west-2",
      datetime = V.datetime,
    }))
    t.eq(own, V.s3_url[3].expected.value) -- "partition us-west-2"
    local from_client = assert(s3.presign_s3_url(c, { bucket = "examplebucket", key = "a.txt" }))
    t.match(from_client, "examplebucket.s3.eu-west-1.amazonaws.com", true)
  end)

  t.it("the client's endpoint gives a path-style URL", function()
    local c = client({ endpoint = "http://localhost:4566/s3/" })
    local got = assert(s3.presign_s3_url(c, {
      bucket = "examplebucket",
      key = "dir/a b+%.txt",
      version_id = "version+/=",
      datetime = V.datetime,
    }))
    t.eq(got, V.s3_url[6].expected.value) -- "custom path-style endpoint"
  end)

  t.it("presign_post and presign_url", function()
    local c = client()
    local post =
      assert(s3.presign_post(c, { bucket = "uploads", key = "a.txt", datetime = V.datetime }))
    t.eq(post.fields.Policy, V.post[1].expected.value.fields.Policy)
    local u = assert(s3.presign_url(c, {
      url = "https://examplebucket.s3.amazonaws.com/test.txt",
      service = "s3",
      datetime = V.datetime,
    }))
    t.eq(u, V.url[1].expected.value)
  end)

  t.it("a credential failure is returned", function()
    local c = client({
      credentials = function()
        return nil, require("distilled.errors").new("AwsCredentialsError", { message = "none" })
      end,
    })
    t.fails_with("AwsCredentialsError", s3.presign_s3_url(c, { bucket = "b", key = "k" }))
    t.fails_with("AwsCredentialsError", s3.presign_request(c, "get_thing", {}))
  end)

  t.it("raises on misuse", function()
    t.raises(function()
      s3.presign_s3_url({}, { bucket = "b", key = "k" })
    end, "generated S3 client")
    t.raises(function()
      s3.presign_request(client(), "nope", {})
    end, "unknown operation nope")
    t.raises(function()
      s3.presign_request(client(), "get_thing", {}, { bogus = true })
    end, "unknown option bogus")
  end)
end)

t.describe("distilled.s3.presign_request: the protocol's request, signed into the URL", function()
  local function params(url)
    local out = {}
    for k, v in string.gmatch(string.match(url, "%?(.*)$") or "", "([^&=]+)=([^&]*)") do
      out[k] = v
    end
    return out
  end

  t.it("hoists x-amz-* headers into the query, keeps SSE and checksums as headers", function()
    local c = client()
    local got = assert(s3.presign_request(c, "put_thing", {
      headers = {
        ["Content-Type"] = "image/png",
        ["x-amz-meta-user"] = "u1",
        ["x-amz-server-side-encryption"] = "AES256",
        ["x-amz-checksum-crc32"] = "AAAAAA==",
        ["x-amz-sdk-checksum-algorithm"] = "CRC32",
        ["If-None-Match"] = "*",
      },
    }, { expires_in = 300, datetime = V.datetime }))
    t.eq(got.method, "PUT")
    local p = params(got.url)
    t.eq(p["x-amz-meta-user"], "u1")
    t.eq(p["X-Amz-Expires"], "300")
    t.eq(
      p["X-Amz-SignedHeaders"],
      "content-type%3Bhost%3Bif-none-match%3Bx-amz-checksum-crc32%3Bx-amz-sdk-checksum-algorithm%3Bx-amz-server-side-encryption"
    )
    t.same(got.headers, {
      ["content-type"] = "image/png",
      ["x-amz-server-side-encryption"] = "AES256",
      ["x-amz-checksum-crc32"] = "AAAAAA==",
      ["x-amz-sdk-checksum-algorithm"] = "CRC32",
      ["if-none-match"] = "*",
    })
    t.eq(p["X-Amz-Date"], V.datetime)
    -- the header signature's leftovers are gone
    t.eq(got.headers.authorization, nil)
    t.eq(got.headers["x-amz-date"], nil)
    t.eq(got.headers["x-amz-content-sha256"], nil)
  end)

  t.it("signs with the scope the protocol used, and pins UNSIGNED-PAYLOAD off s3", function()
    local c = client({ region = "eu-west-1" })
    local got = assert(
      s3.presign_request(
        c,
        "get_thing",
        { service = "s3-object-lambda" },
        { datetime = V.datetime }
      )
    )
    t.match(
      params(got.url)["X-Amz-Credential"],
      "%2Feu-west-1%2Fs3-object-lambda%2Faws4_request",
      true
    )
    t.eq(got.headers["x-amz-content-sha256"], "UNSIGNED-PAYLOAD")
  end)

  t.it("refuses a body", function()
    local got, err = s3.presign_request(client(), "put_thing", { body = "<Tagging/>" })
    t.eq(got, nil)
    t.eq(err.tag, "InvalidInput")
    t.eq(err.member, "PutThing")
    t.match(err.message, "cannot carry", true)
  end)

  t.it("passes the client's resolved options and host to encode", function()
    local c = client({ region = "ap-south-1" })
    local before = #log
    assert(s3.presign_request(c, "get_thing", {}))
    local call = log[before + 1]
    t.eq(call.opts.region, "ap-south-1")
    t.eq(call.op.name, "GetThing")
    t.truthy(call.ctx.host and call.ctx.host.epoch)
  end)

  t.it("defaults to the host clock and 900 seconds", function()
    local got = assert(s3.presign_request(client(), "get_thing", {}))
    local p = params(got.url)
    t.eq(p["X-Amz-Date"], "20130524T000000Z")
    t.eq(p["X-Amz-Expires"], "900")
  end)

  t.it("the SigV4 query signature verifies against a fresh signing of the same request", function()
    local got = assert(
      s3.presign_request(
        client(),
        "get_thing",
        { query = "?versionId=v1" },
        { datetime = V.datetime }
      )
    )
    local again = assert(presign.url({
      url = "https://b.s3.us-east-1.amazonaws.com/k?versionId=v1",
      service = "s3",
      credentials = CREDS,
      datetime = V.datetime,
    }))
    t.eq(got.url, again)
  end)
end)
