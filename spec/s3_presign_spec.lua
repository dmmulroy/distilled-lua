local t = require("spec.harness")
local presign = require("distilled.s3.presign")
local secret = require("distilled.secret")
local crypto = require("distilled.crypto")
local V = require("spec.golden.s3.presign")

-- the credentials of a vector: plain values, or secrets (both must sign the same)
local function creds(input, wrap)
  local w = wrap and secret or function(v)
    return v
  end
  return {
    access_key_id = V.access_key_id,
    secret_access_key = w(V.secret_access_key),
    session_token = input.session_token and w(V.session_token) or nil,
    region = "us-east-1",
  }
end

local function check_result(c, got, err)
  local want = c.expected
  if want.error then
    t.eq(got, nil, c.input.name)
    t.eq(err and err.tag, want.error.tag, c.input.name)
    t.eq(err and err.member, want.error.member, c.input.name)
    t.eq(err and err.message, want.error.message, c.input.name)
  else
    t.eq(err, nil, c.input.name)
    return want.value
  end
end

t.describe("s3.presign: Distilled's presignUrl vectors", function()
  for _, c in ipairs(V.url) do
    t.it(c.input.name, function()
      for _, wrap in ipairs({ false, true }) do
        local i = c.input
        local got, err = presign.url({
          url = i.url,
          service = i.service,
          region = i.region,
          method = i.method,
          expires_in = i.expires_in,
          headers = i.headers,
          datetime = V.datetime,
          credentials = creds(i, wrap),
        })
        local want = check_result(c, got, err)
        if want then
          t.eq(got, want)
        end
      end
    end)
  end
end)

t.describe("s3.presign: Distilled's presignS3Url vectors", function()
  for _, c in ipairs(V.s3_url) do
    t.it(c.input.name, function()
      local i = c.input
      local got, err = presign.s3_url({
        bucket = i.bucket,
        key = i.key,
        method = i.method,
        version_id = i.version_id,
        region = i.region,
        expires_in = i.expires_in,
        content_type = i.content_type,
        response_content_type = i.response_content_type,
        endpoint = i.endpoint,
        datetime = V.datetime,
        credentials = creds(i, true),
      })
      local want = check_result(c, got, err)
      if want then
        t.eq(got, want)
      end
    end)
  end
end)

t.describe("s3.presign: Distilled's presignPost vectors", function()
  for _, c in ipairs(V.post) do
    t.it(c.input.name, function()
      local i = c.input
      local got, err = presign.post({
        bucket = i.bucket,
        key = i.key,
        region = i.region,
        expires_in = i.expires_in,
        conditions = i.conditions,
        fields = i.fields or i.fields_list,
        endpoint = i.endpoint,
        datetime = V.datetime,
        credentials = creds(i, true),
      })
      local want = check_result(c, got, err)
      if not want then
        return
      end
      t.eq(got.url, want.url)
      t.eq(crypto.base64.decode(got.fields.Policy), want.policy)
      t.same(got.fields, want.fields)
      -- field order: the vectors give a map sorted by name, or a list of pairs
      local names, want_names = {}, {}
      for k, p in ipairs(got.field_list) do
        names[k] = p[1]
        t.eq(got.fields[p[1]], p[2])
      end
      for k, p in ipairs(want.field_list) do
        want_names[k] = p[1]
      end
      t.same(names, want_names)
    end)
  end
end)

t.describe("s3.presign: credentials, region and time", function()
  local base = { bucket = "examplebucket", key = "k", datetime = V.datetime }
  local function with(extra)
    local a = {}
    for k, v in pairs(base) do
      a[k] = v
    end
    for k, v in pairs(extra) do
      a[k] = v
    end
    return a
  end
  local want = V.s3_url[10].expected.value -- "session token"

  t.it("takes a credential source and passes it the host", function()
    local seen
    local host = {}
    local got = presign.s3_url(with({
      host = host,
      credentials = function(h)
        seen = h
        return creds({ session_token = true }, true)
      end,
    }))
    t.eq(got, want)
    t.eq(seen, host)
  end)

  t.it("returns the source's error", function()
    t.fails_with(
      "AwsCredentialsError",
      presign.s3_url(with({
        credentials = function()
          return nil, { tag = "AwsCredentialsError", message = "no creds" }
        end,
      }))
    )
  end)

  t.it("turns a raising source into SdkError", function()
    local got, err = presign.s3_url(with({
      credentials = function()
        error("boom")
      end,
    }))
    t.eq(got, nil)
    t.eq(err.tag, "SdkError")
    t.match(err.message, "boom", true)
  end)

  t.it("needs credentials and a region", function()
    t.fails_with("ConfigError", presign.s3_url(with({})))
    local c = creds({})
    c.region = nil
    local got, err = presign.s3_url(with({ credentials = c }))
    t.eq(got, nil)
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "region")
    local c2 = creds({})
    c2.access_key_id = nil
    t.fails_with("ConfigError", presign.post(with({ credentials = c2 })))
  end)

  t.it("never puts the secret key in a URL or a POST form", function()
    local c = creds({ session_token = true }, true)
    local u = assert(presign.s3_url(with({ credentials = c })))
    t.no_match(u, V.secret_access_key, true)
    local p = assert(presign.post(with({ credentials = c })))
    for _, f in ipairs(p.field_list) do
      t.no_match(f[2], V.secret_access_key, true)
    end
  end)

  t.it("reads the clock from now_epoch, then host.epoch", function()
    -- 20130524T000000Z
    local epoch = 1369353600
    local c = creds({ session_token = true })
    local a =
      presign.s3_url({ bucket = "examplebucket", key = "k", credentials = c, now_epoch = epoch })
    local b = presign.s3_url({
      bucket = "examplebucket",
      key = "k",
      credentials = c,
      host = {
        epoch = function()
          return epoch
        end,
      },
    })
    t.eq(a, want)
    t.eq(b, want)
  end)

  t.it("formats the policy expiration as toISOString", function()
    t.eq(presign._iso_string(1369353600 * 1000 + 900500), "2013-05-24T00:15:00.500Z")
    t.eq(presign._iso_string(0), "1970-01-01T00:00:00.000Z")
  end)

  t.it("raises on misuse", function()
    t.raises(function()
      presign.s3_url({ bucket = "b" })
    end, "bucket and key")
    t.raises(function()
      presign.s3_url(with({ bogus = 1 }))
    end, "unknown option bogus")
    t.raises(function()
      presign.url({ url = "https://x" })
    end, "url and service")
  end)
end)
