-- distilled.aws.credentials: the default chain and its sources, ported from Distilled's
-- packages/aws/test/credential-providers/credential-providers.test.ts (fromEnv, chain,
-- fromIni, fromProcess, fromTokenFile, fromHttp / fromContainerMetadata,
-- fromInstanceMetadata, fromNodeProviderChain). Files come from spec/fixtures/aws/creds;
-- processes run through a fake host.exec and requests through a routing transport.
local t = require("spec.harness")
local testing = require("distilled.testing")
local aws_credentials = require("distilled.aws.credentials")

local DIR = t.root .. "/spec/fixtures/aws/creds/"
-- one hour after distilled.testing.host's epoch (1700000000)
local IN_ONE_HOUR = "2023-11-14T23:13:20Z"

-- a host whose transport answers `handler(req)` and records every request
local function host_with(env, handler, exec)
  local calls = {}
  local merged = {
    AWS_CONFIG_FILE = DIR .. "config",
    AWS_SHARED_CREDENTIALS_FILE = DIR .. "credentials",
    AWS_EC2_METADATA_DISABLED = "true",
  }
  for k, v in pairs(env or {}) do
    merged[k] = v ~= false and v or nil
  end
  local h = testing.host({ env = merged, exec = exec })
  h.transport = function(req)
    calls[#calls + 1] = req
    if not handler then
      return nil, require("distilled.errors").new("TransportError", { message = "no network" })
    end
    return handler(req)
  end
  h.calls = calls
  return h
end

local function assume_role_xml(op, key)
  return {
    status = 200,
    headers = { ["content-type"] = "text/xml" },
    body = "<"
      .. op
      .. 'Response xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><'
      .. op
      .. "Result><AssumedRoleUser><Arn>arn:aws:sts::123456789012:assumed-role/Role/s</Arn>"
      .. "<AssumedRoleId>AROA:s</AssumedRoleId></AssumedRoleUser><Credentials><AccessKeyId>"
      .. key
      .. "</AccessKeyId><SecretAccessKey>secret-"
      .. key
      .. "</SecretAccessKey><SessionToken>session-"
      .. key
      .. "</SessionToken><Expiration>"
      .. IN_ONE_HOUR
      .. "</Expiration></Credentials></"
      .. op
      .. "Result></"
      .. op
      .. "Response>",
  }
end

local function json_creds(key)
  return {
    status = 200,
    headers = { ["content-type"] = "application/json" },
    body = '{"AccessKeyId":"'
      .. key
      .. '","SecretAccessKey":"secret-'
      .. key
      .. '","Token":"token-'
      .. key
      .. '","Expiration":"'
      .. IN_ONE_HOUR
      .. '"}',
  }
end

-- credential_process stand-in: the command names the output
local function fake_exec(argv)
  local command = argv[#argv]
  if string.find(command, "--v1", 1, true) then
    return {
      code = 0,
      ok = true,
      stdout = '{"Version":1,"AccessKeyId":"AKIA-proc","SecretAccessKey":"secret-proc",'
        .. '"SessionToken":"session-proc","AccountId":"111111111111"}\n',
      stderr = "",
    }
  elseif string.find(command, "--v2", 1, true) then
    return {
      code = 0,
      ok = true,
      stdout = '{"Version":2,"AccessKeyId":"a","SecretAccessKey":"b"}',
      stderr = "",
    }
  end
  return { code = 0, ok = true, stdout = "nope\n", stderr = "" }
end

t.describe("aws credentials: fromEnv", function()
  t.it("reads the key pair, token, expiration and account id", function()
    local h = host_with({
      AWS_ACCESS_KEY_ID = "AKIA-env",
      AWS_SECRET_ACCESS_KEY = "secret-env",
      AWS_SESSION_TOKEN = "session-env",
      AWS_CREDENTIAL_EXPIRATION = IN_ONE_HOUR,
      AWS_ACCOUNT_ID = "123456789012",
      AWS_REGION = "us-west-1",
    })
    local c, err = aws_credentials.env()(h)
    t.truthy(c, err and err.message)
    t.eq(c.access_key_id, "AKIA-env")
    t.eq(c.secret_access_key, "secret-env")
    t.eq(c.session_token, "session-env")
    t.eq(c.expiration, 1700003600)
    t.eq(c.account_id, "123456789012")
    t.eq(c.region, "us-west-1")
  end)

  t.it("fails with a typed error and hints when the pair is missing", function()
    local c, err = aws_credentials.env()(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "environment variable credentials", true)
    t.truthy(err.hints and #err.hints > 0, "hints")
    t.truthy(err.categories.AuthError, "AuthError category")
  end)
end)

t.describe("aws credentials: fromIni", function()
  t.it("static credentials from the credentials file, by AWS_PROFILE", function()
    local c = assert(aws_credentials.profile({})(host_with({})))
    t.eq(c.access_key_id, "AKIA-default")
    t.eq(c.secret_access_key, "secret-default")
    t.eq(c.session_token, nil)
    t.eq(c.region, "eu-central-1")
    c = assert(aws_credentials.profile({})(host_with({ AWS_PROFILE = "other" })))
    t.eq(c.access_key_id, "AKIA-other")
    t.eq(c.session_token, "session-other")
    t.eq(c.account_id, "999999999999")
    t.eq(c.region, "ap-northeast-1")
  end)

  t.it("a profile that is not there", function()
    local c, err = aws_credentials.profile({ profile = "nope" })(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "[nope]", true)
  end)

  t.it("a config file that cannot be parsed fails with the parse error", function()
    local c, err = aws_credentials.profile({})(host_with({ AWS_CONFIG_FILE = DIR .. "bad_config" }))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, 'invalid profile name "profile __proto__"', true)
  end)

  t.it("role_arn + source_profile assumes the role through STS, signed by the source", function()
    local h = host_with({}, function(req)
      return assume_role_xml("AssumeRole", "ASIA-admin")
    end)
    local c, err = aws_credentials.profile({ profile = "admin" })(h)
    t.truthy(c, err and err.message)
    t.eq(c.access_key_id, "ASIA-admin")
    t.eq(c.secret_access_key, "secret-ASIA-admin")
    t.eq(c.session_token, "session-ASIA-admin")
    t.eq(c.account_id, "123456789012")
    t.eq(c.expiration, 1700003600)
    t.eq(#h.calls, 1)
    local call = h.calls[1]
    t.match(call.url, "^https://sts%.us%-west%-2%.amazonaws%.com/")
    local auth = call.headers.Authorization or call.headers.authorization
    t.match(auth, "AKIA-base/", true)
    t.match(auth, "/us-west-2/sts/", true)
    t.match(call.body, "Action=AssumeRole", true)
    t.match(call.body, "RoleArn=arn%3Aaws%3Aiam%3A%3A123456789012%3Arole%2FAdmin", true)
    t.match(call.body, "ExternalId=ext", true)
    t.match(call.body, "DurationSeconds=900", true)
  end)

  t.it("an STS error fails the profile and names the code, never the keys", function()
    local h = host_with({}, function()
      return {
        status = 403,
        headers = { ["content-type"] = "text/xml" },
        body = "<ErrorResponse><Error><Code>AccessDenied</Code><Message>not allowed</Message></Error></ErrorResponse>",
      }
    end)
    local c, err = aws_credentials.profile({ profile = "admin" })(h)
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "AccessDenied", true)
    t.no_match(err.message, "secret-base", true)
  end)

  t.it("mfa_serial without a code provider is a final failure", function()
    local c, err = aws_credentials.profile({ profile = "mfa" })(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "multi-factor authentication", true)
  end)

  t.it("mfa_serial asks the code provider and sends the code", function()
    local asked
    local h = host_with({}, function()
      return assume_role_xml("AssumeRole", "ASIA-mfa")
    end)
    local c = assert(aws_credentials.profile({
      profile = "mfa",
      mfa_code = function(serial)
        asked = serial
        return "123456"
      end,
    })(h))
    t.eq(c.access_key_id, "ASIA-mfa")
    t.eq(asked, "arn:aws:iam::123456789012:mfa/me")
    t.match(h.calls[1].body, "TokenCode=123456", true)
  end)

  t.it("a source_profile cycle is reported", function()
    local c, err = aws_credentials.profile({ profile = "a" })(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "cycle", true)
  end)

  t.it("credential_source = Environment without role_arn is unresolvable", function()
    local c, err = aws_credentials.profile({ profile = "env" })(host_with({
      AWS_ACCESS_KEY_ID = "AKIA-env",
      AWS_SECRET_ACCESS_KEY = "secret-env",
    }))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "[env]", true)
  end)

  t.it("credential_process runs the command through host.exec", function()
    local argv
    local c = assert(aws_credentials.profile({ profile = "proc" })(host_with({}, nil, function(a)
      argv = a
      return fake_exec(a)
    end)))
    t.eq(c.access_key_id, "AKIA-proc")
    t.eq(c.session_token, "session-proc")
    t.eq(c.account_id, "111111111111")
    t.eq(argv[1], "/bin/sh")
    t.eq(argv[3], "print-creds --v1")
    c = assert(aws_credentials.process("proc")(host_with({}, nil, fake_exec)))
    t.eq(c.access_key_id, "AKIA-proc")
  end)

  t.it("credential_process output is validated", function()
    local h = host_with({}, nil, fake_exec)
    local _, err = aws_credentials.process("v2")(h)
    t.match(err.message, "did not return Version 1", true)
    _, err = aws_credentials.process("junk")(h)
    t.match(err.message, "invalid JSON", true)
    t.no_match(err.message, "nope", true)
    _, err = aws_credentials.process("missing")(h)
    t.match(err.message, "could not be found", true)
  end)
end)

t.describe("aws credentials: fromTokenFile", function()
  t.it("posts the token to AssumeRoleWithWebIdentity unsigned", function()
    local h = host_with({
      AWS_WEB_IDENTITY_TOKEN_FILE = DIR .. "token",
      AWS_ROLE_ARN = "arn:aws:iam::123456789012:role/Pod",
      AWS_ROLE_SESSION_NAME = "pod",
      AWS_REGION = "ap-southeast-2",
    }, function()
      return assume_role_xml("AssumeRoleWithWebIdentity", "ASIA-pod")
    end)
    local c, err = aws_credentials.token_file({})(h)
    t.truthy(c, err and err.message)
    t.eq(c.access_key_id, "ASIA-pod")
    t.eq(#h.calls, 1)
    local call = h.calls[1]
    t.match(call.url, "^https://sts%.ap%-southeast%-2%.amazonaws%.com/")
    t.eq(call.headers.Authorization or call.headers.authorization, nil)
    t.match(call.body, "Action=AssumeRoleWithWebIdentity", true)
    t.match(call.body, "WebIdentityToken=jwt-token", true)
    t.match(call.body, "RoleSessionName=pod", true)
  end)

  t.it("fails when not configured", function()
    local c, err = aws_credentials.token_file({})(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
  end)
end)

t.describe("aws credentials: container metadata", function()
  t.it("a relative URI resolves against the ECS host with the auth token", function()
    local h = host_with({
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = "/v2/creds",
      AWS_CONTAINER_AUTHORIZATION_TOKEN = "tok",
    }, function()
      return json_creds("ASIA-ecs")
    end)
    local c = assert(aws_credentials.container()(h))
    t.eq(c.access_key_id, "ASIA-ecs")
    t.eq(c.session_token, "token-ASIA-ecs")
    t.eq(h.calls[1].url, "http://169.254.170.2/v2/creds")
    t.eq(h.calls[1].headers.Authorization or h.calls[1].headers.authorization, "tok")
  end)

  t.it("a full URI must be https, loopback or a container host", function()
    local c, err = aws_credentials.container()(host_with({
      AWS_CONTAINER_CREDENTIALS_FULL_URI = "http://example.com/creds",
    }))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "URL not accepted", true)
    t.truthy(aws_credentials._accepted_url("http://127.0.0.1:8080/x"))
    t.truthy(aws_credentials._accepted_url("https://example.com/x"))
    t.truthy(aws_credentials._accepted_url("http://[fd00:ec2::23]/x"))
  end)

  t.it("the token file is read from disk", function()
    local h = host_with({
      AWS_CONTAINER_CREDENTIALS_FULL_URI = "http://169.254.170.23/v1/credentials",
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = DIR .. "token",
    }, function()
      return json_creds("ASIA-eks")
    end)
    local c = assert(aws_credentials.container()(h))
    t.eq(c.access_key_id, "ASIA-eks")
    t.eq(h.calls[1].headers.Authorization or h.calls[1].headers.authorization, "jwt-token")
  end)

  t.it("a 4xx surfaces the endpoint's error code, after the retries", function()
    local h = host_with({ AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = "/v2/creds" }, function()
      return { status = 403, headers = {}, body = '{"Code":"AccessDenied","Message":"no"}' }
    end)
    local c, err = aws_credentials.container()(h)
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "403 AccessDenied no", true)
    t.eq(#h.calls, 4)
    t.eq(#h.sleeps, 3)
  end)

  t.it("nothing configured", function()
    local c, err = aws_credentials.container()(host_with({}))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "No HTTP credential provider host provided", true)
  end)
end)

t.describe("aws credentials: instance metadata", function()
  local function imds(token_status)
    return function(req)
      if req.method == "PUT" then
        if token_status ~= 200 then
          return { status = token_status, headers = {}, body = "" }
        end
        return { status = 200, headers = {}, body = "imds-token" }
      end
      if string.find(req.url, "/security%-credentials/$") then
        return { status = 200, headers = {}, body = "my-role\n" }
      end
      if string.find(req.url, "/security%-credentials/my%-role$") then
        return json_creds("ASIA-imds")
      end
      return { status = 404, headers = {}, body = "" }
    end
  end

  t.it("IMDSv2: token, role name, then credentials", function()
    local h = host_with({ AWS_EC2_METADATA_DISABLED = false }, imds(200))
    local c = assert(aws_credentials.instance_metadata()(h))
    t.eq(c.access_key_id, "ASIA-imds")
    t.eq(#h.calls, 3)
    t.eq(h.calls[1].method, "PUT")
    t.eq(h.calls[1].url, "http://169.254.169.254/latest/api/token")
    t.eq(h.calls[2].headers["x-aws-ec2-metadata-token"], "imds-token")
    t.eq(h.calls[3].url, "http://169.254.169.254/latest/meta-data/iam/security-credentials/my-role")
  end)

  t.it("falls back to IMDSv1 when the token endpoint is 404", function()
    local h = host_with({ AWS_EC2_METADATA_DISABLED = false }, imds(404))
    local c = assert(aws_credentials.instance_metadata()(h))
    t.eq(c.access_key_id, "ASIA-imds")
    t.eq(h.calls[2].headers["x-aws-ec2-metadata-token"], nil)
  end)

  t.it("the IMDSv1 fallback can be blocked", function()
    local h = host_with(
      { AWS_EC2_METADATA_DISABLED = false, AWS_EC2_METADATA_V1_DISABLED = "true" },
      imds(404)
    )
    local c, err = aws_credentials.instance_metadata()(h)
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "AWS_EC2_METADATA_V1_DISABLED", true)
  end)

  t.it("a custom endpoint", function()
    local h = host_with({
      AWS_EC2_METADATA_DISABLED = false,
      AWS_EC2_METADATA_SERVICE_ENDPOINT = "http://127.0.0.1:1338",
    }, imds(200))
    assert(aws_credentials.instance_metadata()(h))
    t.eq(h.calls[1].url, "http://127.0.0.1:1338/latest/api/token")
  end)
end)

t.describe("aws credentials: the default chain (fromNodeProviderChain)", function()
  t.it("the environment wins when AWS_PROFILE is unset", function()
    local c = assert(aws_credentials.chain()(host_with({
      AWS_ACCESS_KEY_ID = "AKIA-env",
      AWS_SECRET_ACCESS_KEY = "secret-env",
    })))
    t.eq(c.access_key_id, "AKIA-env")
  end)

  t.it("AWS_PROFILE sends the chain to the profile before the environment", function()
    local c = assert(aws_credentials.chain()(host_with({
      AWS_ACCESS_KEY_ID = "AKIA-env",
      AWS_SECRET_ACCESS_KEY = "secret-env",
      AWS_PROFILE = "other",
    })))
    t.eq(c.access_key_id, "AKIA-other")
  end)

  t.it("falls through to the container endpoint", function()
    local h = host_with({
      AWS_SHARED_CREDENTIALS_FILE = DIR .. "missing",
      AWS_CONFIG_FILE = DIR .. "missing",
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = "/v2/creds",
    }, function()
      return json_creds("ASIA-ecs")
    end)
    local c = assert(aws_credentials.chain()(h))
    t.eq(c.access_key_id, "ASIA-ecs")
  end)

  t.it("a config file that cannot be parsed still falls through", function()
    local c = assert(aws_credentials.chain()(host_with({
      AWS_CONFIG_FILE = DIR .. "bad_config",
      AWS_SHARED_CREDENTIALS_FILE = DIR .. "missing",
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = "/v2/creds",
    }, function()
      return json_creds("ASIA-ecs")
    end)))
    t.eq(c.access_key_id, "ASIA-ecs")
  end)

  t.it("with IMDS disabled and nothing else, fails with the final message", function()
    local c, err = aws_credentials.chain()(host_with({
      AWS_SHARED_CREDENTIALS_FILE = DIR .. "missing",
      AWS_CONFIG_FILE = DIR .. "missing",
    }))
    t.fails_with("AwsCredentialsError", c, err)
    t.match(err.message, "Could not load credentials from any providers", true)
  end)

  t.it("the region comes from the profile", function()
    t.eq(aws_credentials.region(host_with({}), "other"), "ap-northeast-1")
    t.eq(aws_credentials.region(host_with({ AWS_REGION = "sa-east-1" }), "other"), "sa-east-1")
    t.eq(aws_credentials.region(host_with({})), "eu-central-1")
  end)

  t.it("expiry: a credential inside the refresh window is expired", function()
    t.truthy(aws_credentials.expired({ expiration = 1000 }, 1000 - 299))
    t.falsy(aws_credentials.expired({ expiration = 1000 }, 1000 - 301))
    t.falsy(aws_credentials.expired({}, 1000))
  end)
end)

t.describe("aws credentials: ini parsing (util/parse-ini.ts)", function()
  t.it("sections, profiles, sub-properties and comments", function()
    local s = assert(
      aws_credentials.parse_ini(
        "[default]\nregion = us-east-1 # comment\n"
          .. "s3 =\n  max_concurrent_requests = 10\n[profile x]\nkey=v=w\n; c\n",
        "x"
      )
    )
    t.eq(s.default.region, "us-east-1")
    t.eq(s.default["s3.max_concurrent_requests"], "10")
    t.eq(s["profile.x"].key, "v=w") -- parse-ini.ts joins the prefix with "."
  end)
end)
