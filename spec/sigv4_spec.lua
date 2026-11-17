local t = require("spec.harness")
local sigv4 = require("distilled.sigv4")
local secret = require("distilled.secret")
local hex = require("distilled.crypto.hex")
local V = require("spec.golden.sigv4.vectors")

local function unhex(h)
  return (h:gsub("..", function(p)
    return string.char(tonumber(p, 16))
  end))
end

-- a query parameter of a signed URL (values here are plain: no escapes to undo)
local function param(url, name)
  return url:match("[?&]" .. name:gsub("%-", "%%-") .. "=([^&#]*)")
end

-- AWS SigV4 documentation examples (S3 "GET Object" and query-string auth), as in
-- aws4signer/test/index.test.ts
local DOCS = {
  access_key_id = "AKIAIOSFODNN7EXAMPLE",
  secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
}

local function args_of(input, extra)
  local args = {
    request = {
      method = input.method,
      url = input.url,
      headers = input.headers,
      body = input.body_hex and unhex(input.body_hex) or input.body,
    },
    credentials = {
      access_key_id = V.access_key_id,
      secret_access_key = V.secret_access_key,
      session_token = input.session_token and V.session_token or nil,
    },
    service = input.service,
    region = input.region,
    datetime = V.datetime,
    sign_query = input.sign_query,
    all_headers = input.all_headers,
    hash_payload = input.hash_payload,
    append_session_token = input.append_session_token,
    single_encode = input.single_encode,
  }
  for k, v in pairs(extra or {}) do
    args[k] = v
  end
  return args
end

t.describe("sigv4: aws4signer's tests (AWS documentation examples)", function()
  t.it("signs a header-authenticated S3 GET", function()
    local signed = assert(sigv4.sign({
      request = {
        method = "GET",
        url = "https://examplebucket.s3.amazonaws.com/test.txt",
        headers = { Range = "bytes=0-9" },
      },
      credentials = DOCS,
      service = "s3",
      region = "us-east-1",
      datetime = "20130524T000000Z",
    }))
    t.eq(
      signed.headers.authorization,
      "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        .. "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
        .. "Signature=5c0d4ff29e72b8f94c5b6720369921e587e39bf7a64e456887dec4b43a2d1b77"
    )
    t.eq(signed.headers["x-amz-content-sha256"], "UNSIGNED-PAYLOAD")
    t.eq(signed.headers.range, "bytes=0-9")
  end)

  t.it("presigns an S3 GET into the query string", function()
    local signed = assert(sigv4.sign({
      request = { method = "GET", url = "https://examplebucket.s3.amazonaws.com/test.txt" },
      credentials = DOCS,
      service = "s3",
      region = "us-east-1",
      datetime = "20130524T000000Z",
      sign_query = true,
    }))
    t.eq(param(signed.url, "X-Amz-Expires"), "86400")
    t.eq(param(signed.url, "X-Amz-SignedHeaders"), "host")
    t.eq(
      param(signed.url, "X-Amz-Signature"),
      "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    )
    t.eq(signed.headers.authorization, nil)
  end)

  t.it("presigns an R2 object URL with region auto", function()
    local signed = assert(sigv4.sign({
      request = {
        method = "PUT",
        url = "https://0123456789abcdef.r2.cloudflarestorage.com/bucket/a/b.txt?X-Amz-Expires=900",
      },
      credentials = DOCS,
      service = "s3",
      region = "auto",
      datetime = "20130524T000000Z",
      sign_query = true,
    }))
    t.eq(signed.method, "PUT")
    t.eq(
      param(signed.url, "X-Amz-Credential"),
      "AKIAIOSFODNN7EXAMPLE%2F20130524%2Fauto%2Fs3%2Faws4_request"
    )
    t.eq(param(signed.url, "X-Amz-Expires"), "900")
    t.match(param(signed.url, "X-Amz-Signature"), "^" .. string.rep("%x", 64) .. "$")
  end)

  t.it("fails with InvalidInput on a relative URL", function()
    t.fails_with(
      "InvalidInput",
      sigv4.sign({
        request = { url = "/relative" },
        credentials = DOCS,
        service = "s3",
        region = "us-east-1",
        now_epoch = 0,
      })
    )
  end)

  t.it("derives the documented signing key (AWS docs, IAM example)", function()
    local key =
      sigv4.signing_key("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam")
    t.eq(hex.encode(key), "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
  end)
end)

t.describe(
  "sigv4: same requests as Distilled and aws4fetch (spec/golden/sigv4/vectors.lua)",
  function()
    t.it("every case: method, URL and every header byte for byte", function()
      t.truthy(#V.cases >= 50)
      for _, c in ipairs(V.cases) do
        local signed, err = sigv4.sign(args_of(c.input))
        t.truthy(signed, c.input.name .. ": " .. tostring(err))
        t.eq(signed.method, c.expected.method, c.input.name)
        t.eq(signed.url, c.expected.url, c.input.name)
        t.same(signed.headers, c.expected.headers, c.input.name)
      end
    end)

    t.it("the canonical request equals aws4fetch's canonicalString()", function()
      local checked = 0
      for _, c in ipairs(V.cases) do
        if c.expected.canonical then
          checked = checked + 1
          t.eq(sigv4.canonical_request(args_of(c.input)), c.expected.canonical, c.input.name)
        end
      end
      t.truthy(checked >= 45)
    end)

    t.it(
      "the AWS SigV4 test suite: same as Distilled, and the published signature where it does",
      function()
        local reproduced, differ = 0, {}
        for _, c in ipairs(V.suite) do
          local i = c.input
          local signed = assert(sigv4.sign({
            request = { method = i.method, url = i.url, headers = i.headers, body = i.body },
            credentials = {
              access_key_id = "AKIDEXAMPLE",
              secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
              session_token = i.session_token,
            },
            service = "service",
            region = "us-east-1",
            datetime = "20150830T123600Z",
            all_headers = i.all_headers,
            append_session_token = i.append_session_token,
          }))
          t.eq(signed.headers.authorization, c.distilled, i.name)
          if c.reproduced then
            reproduced = reproduced + 1
            t.eq(signed.headers.authorization, c.published, i.name)
          else
            differ[#differ + 1] = i.name
          end
        end
        -- aws4fetch encodes paths twice outside S3 (AWS requires it of real services), so
        -- the suite's raw-space and raw-UTF-8 paths are signed differently. Known, as Distilled.
        table.sort(differ)
        t.same(differ, { "get-space", "get-utf8" })
        t.eq(reproduced, #V.suite - 2)
      end
    )

    t.it("guesses service and region from the host like aws4fetch", function()
      for _, g in ipairs(V.guesses) do
        local headers = g[4] and { ["X-Amz-Target"] = g[4] } or nil
        local service, region = sigv4.guess_service_region(g[1], headers)
        t.eq(service, g[2], g[1])
        t.eq(region, g[3], g[1])
      end
    end)

    t.it("presign writes X-Amz-Expires and matches Distilled's presign", function()
      for _, p in ipairs(V.presign) do
        local url = assert(sigv4.presign({
          url = p.url,
          method = p.method,
          credentials = {
            access_key_id = V.access_key_id,
            secret_access_key = V.secret_access_key,
            session_token = p.session_token and V.session_token or nil,
          },
          datetime = V.datetime,
          expires_in = p.expires_in,
        }))
        t.eq(url, p.expected, p.url)
      end
    end)
  end
)

t.describe("sigv4: time, secrets, copies", function()
  t.it("now_epoch becomes the UTC signing time", function()
    local cases = {
      { 1369353600, "20130524T000000Z" },
      { 1709168461, "20240229T010101Z" },
      { 1704067199, "20231231T235959Z" },
      { 951782400, "20000229T000000Z" },
      { 0, "19700101T000000Z" },
      { 4102444799, "20991231T235959Z" },
      { 1369353600.75, "20130524T000000Z" },
    }
    for _, c in ipairs(cases) do
      t.eq(sigv4.amz_datetime(c[1]), c[2], tostring(c[1]))
    end
    local by_epoch = assert(sigv4.sign({
      request = {
        url = "https://examplebucket.s3.amazonaws.com/test.txt",
        headers = { Range = "bytes=0-9" },
      },
      credentials = DOCS,
      service = "s3",
      region = "us-east-1",
      now_epoch = 1369353600,
    }))
    t.match(
      by_epoch.headers.authorization,
      "Signature=5c0d4ff29e72b8f94c5b6720369921e587e39bf7a64e456887dec4b43a2d1b77$"
    )
    t.eq(by_epoch.headers["x-amz-date"], "20130524T000000Z")
  end)

  t.it("credentials may be secrets and sign the same", function()
    local c = V.cases[4] -- SQS POST with a session token
    local plain = assert(sigv4.sign(args_of(c.input)))
    local args = args_of(c.input)
    args.credentials = {
      access_key_id = V.access_key_id,
      secret_access_key = secret(V.secret_access_key),
      session_token = secret(V.session_token),
    }
    local wrapped = assert(sigv4.sign(args))
    t.same(wrapped.headers, plain.headers)
    t.eq(wrapped.headers["x-amz-security-token"], V.session_token)
  end)

  t.it("returns a copy: the input request is unchanged and other fields are kept", function()
    local request = {
      method = "POST",
      url = "https://sqs.us-east-1.amazonaws.com/",
      headers = { ["Content-Type"] = "text/plain" },
      body = "x",
      timeout = 5,
    }
    local signed = assert(sigv4.sign({ request = request, credentials = DOCS, now_epoch = 0 }))
    t.same(request.headers, { ["Content-Type"] = "text/plain" })
    t.eq(request.url, "https://sqs.us-east-1.amazonaws.com/")
    t.eq(signed.timeout, 5)
    t.eq(signed.body, "x")
    t.eq(signed.headers["content-type"], "text/plain")
    t.match(signed.headers.authorization, "/19700101/us%-east%-1/sqs/aws4_request")
  end)

  t.it("an empty body defaults the method to GET and hashes the empty string", function()
    local signed = assert(sigv4.sign({
      request = { url = "https://execute-api.us-east-1.amazonaws.com/x", body = "" },
      credentials = DOCS,
      now_epoch = 0,
      hash_payload = true,
    }))
    t.eq(signed.method, "GET")
    t.eq(
      signed.headers["x-amz-content-sha256"],
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
  end)
end)

t.describe("sigv4: failures", function()
  local function sign_with(request, credentials)
    return sigv4.sign({
      request = request,
      credentials = credentials or DOCS,
      service = "sqs",
      region = "us-east-1",
      now_epoch = 0,
    })
  end

  t.it("bad URLs are InvalidInput", function()
    for _, u in ipairs({
      "",
      "/x",
      "ftp://a.com/x",
      "https://",
      "https://a.com:99999/",
      "https://a b.com/",
      "nope",
    }) do
      t.fails_with("InvalidInput", sign_with({ url = u }))
    end
  end)

  t.it("bad headers are InvalidInput, and the message never carries the value", function()
    local e = t.fails_with(
      "InvalidInput",
      sign_with({ url = "https://a.com/", headers = { ["x-token"] = "s3cr3t\r\nInjected: 1" } })
    )
    t.no_match(e.message, "s3cr3t", true)
    t.fails_with(
      "InvalidInput",
      sign_with({ url = "https://a.com/", headers = { ["bad name"] = "v" } })
    )
    t.fails_with("InvalidInput", sign_with({ url = "https://a.com/", headers = { ["x-n"] = 1 } }))
    t.fails_with(
      "InvalidInput",
      sign_with({ url = "https://a.com/", headers = { ["x-n"] = "a\0b" } })
    )
  end)

  t.it("missing credentials are ConfigError naming the key, never the secret", function()
    local e = t.fails_with(
      "ConfigError",
      sign_with({ url = "https://a.com/" }, { secret_access_key = "s3cr3t" })
    )
    t.eq(e.key, "access_key_id")
    t.no_match(tostring(e), "s3cr3t", true)
    e =
      t.fails_with("ConfigError", sign_with({ url = "https://a.com/" }, { access_key_id = "AKID" }))
    t.eq(e.key, "secret_access_key")
    e = t.fails_with(
      "ConfigError",
      sign_with(
        { url = "https://a.com/" },
        { access_key_id = "AKID", secret_access_key = "x", session_token = 5 }
      )
    )
    t.eq(e.key, "session_token")
  end)

  t.it("misuse raises: unknown or mistyped arguments, no time, bad datetime, no request", function()
    local base = { request = { url = "https://a.com/" }, credentials = DOCS, now_epoch = 0 }
    local function with(k, v)
      local a = {}
      for kk, vv in pairs(base) do
        a[kk] = vv
      end
      a[k] = v
      return a
    end
    t.raises(function()
      sigv4.sign(with("sign_qeury", true))
    end, "unknown argument sign_qeury")
    t.raises(function()
      sigv4.sign(with("region", 5))
    end, "region must be a string")
    t.raises(function()
      sigv4.sign(with("now_epoch", nil))
    end, "now_epoch")
    t.raises(function()
      sigv4.sign(with("datetime", "2024-01-15"))
    end, "datetime must look like")
    t.raises(function()
      sigv4.sign(with("now_epoch", -1))
    end, "Unix time")
    t.raises(function()
      sigv4.sign(with("request", nil))
    end, "request and credentials are required")
    t.raises(function()
      sigv4.sign(with("request", { url = "https://a.com/", body = { 1 } }))
    end, "body must be a string")
    t.raises(function()
      sigv4.sign("x")
    end, "named arguments")
    t.raises(function()
      sigv4.presign({ url = "https://a.com/", credentials = DOCS, now_epoch = 0, sign_query = true })
    end, "unknown argument sign_query")
  end)

  t.it("presign of a bad URL is InvalidInput", function()
    t.fails_with(
      "InvalidInput",
      sigv4.presign({ url = "nope", credentials = DOCS, now_epoch = 0, expires_in = 60 })
    )
    t.fails_with("InvalidInput", sigv4.presign({ url = "nope", credentials = DOCS, now_epoch = 0 }))
  end)
end)

t.describe("sigv4: URL handling (WHATWG subset)", function()
  t.it("parses and normalises like new URL()", function()
    local u =
      sigv4._parse_url("HTTPS://User:p w@Example.COM:0443/a/./b/../c%2e/%2E%2e/d e?q=a b'#f g")
    t.eq(u.scheme, "https")
    t.eq(u.host, "example.com")
    t.eq(u.userinfo, "User:p%20w")
    t.eq(u.path, "/a/d%20e")
    t.eq(u.query, "q=a%20b%27")
    t.eq(u.fragment, "f%20g")
    t.eq(sigv4._parse_url("http://a.com:8080").path, "/")
    t.eq(sigv4._parse_url("http://a.com:8080").host, "a.com:8080")
    t.eq(sigv4._parse_url("https:\\\\a.com\\b\\c").path, "/b/c")
    t.eq(sigv4._parse_url("https://a.com/b^c{d}`").path, "/b%5Ec%7Bd%7D%60")
    t.eq(sigv4._parse_url("https://a.com/x?").query, "")
    t.eq(sigv4._parse_url("https://a.com/x").query, nil)
  end)

  t.it("repairs ill-formed UTF-8 one maximal subpart at a time (WHATWG decoder)", function()
    local R = "\239\191\189"
    local repair = sigv4._utf8_repair
    t.eq(repair("abc"), "abc")
    t.eq(repair("caf\195\169"), "caf\195\169")
    t.eq(repair("\255"), R)
    t.eq(repair("\195"), R)
    t.eq(repair("\226\130"), R) -- truncated 3-byte sequence: one replacement
    t.eq(repair("\226\130a"), R .. "a")
    t.eq(repair("\237\160\128"), R .. R .. R) -- a surrogate: three
    t.eq(repair("\240\159\152\128"), "\240\159\152\128")
    t.eq(repair("\192\175"), R .. R) -- overlong
  end)
end)
