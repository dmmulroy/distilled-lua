-- The generated AWS clients end to end (clients/aws, distilled.aws.protocol): retry of
-- throttling and transient errors, the region order, the custom endpoint, idempotency
-- tokens, expired credentials, error classes and their categories, secrets kept out of
-- errors, SigV4 on every attempt, the bearer and SigV2 services, gzip request bodies.
local t = require("spec.harness")
local testing = require("distilled.testing")
local json = require("distilled.json")
local aws_credentials = require("distilled.aws.credentials")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local SQS = require("aws.sqs")
local DynamoDB = require("aws.dynamodb")

local CREDS = aws_credentials.static({
  access_key_id = "AKIDEXAMPLE",
  secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
})

local function json_res(status, body, headers)
  local h = { ["content-type"] = "application/x-amz-json-1.0" }
  for k, v in pairs(headers or {}) do
    h[k] = v
  end
  return { status = status, headers = h, body = body }
end

local function client(class, responses, extra)
  local host = testing.host({ responses = responses, env = (extra or {}).env })
  local o = { region = "us-east-1", credentials = CREDS, host = host }
  for k, v in pairs(extra or {}) do
    if k ~= "env" then
      -- false: leave the option out
      o[k] = v or nil
    end
  end
  return class.new(o), host
end

local function header(req, name)
  for k, v in pairs(req.headers or {}) do
    if string.lower(k) == name then
      return v
    end
  end
  return nil
end

t.describe("aws client: requests", function()
  t.it("an awsJson1_0 call: target, content type, SigV4 scope, the rules' endpoint", function()
    local c, host = client(DynamoDB, { json_res(200, '{"TableNames":["a"]}') })
    local out, err = c:list_tables({ Limit = 1 })
    t.truthy(out, err and err.message)
    t.same(out.TableNames, { "a" })
    local req = host.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://dynamodb.us-east-1.amazonaws.com/")
    t.eq(header(req, "x-amz-target"), "DynamoDB_20120810.ListTables")
    t.eq(header(req, "content-type"), "application/x-amz-json-1.0")
    t.match(
      header(req, "authorization"),
      "Credential=AKIDEXAMPLE/20231114/us-east-1/dynamodb/aws4_request",
      true
    )
    t.eq(header(req, "x-amz-date"), "20231114T221320Z")
    t.same(json.decode(req.body), { Limit = 1 })
  end)

  t.it("region order: the call's region, then the option, then the credentials'", function()
    local c, host = client(DynamoDB, { json_res(200, "{}"), json_res(200, "{}") })
    assert(c:list_tables({ region = "eu-west-1" }))
    t.eq(host.requests[1].url, "https://dynamodb.eu-west-1.amazonaws.com/")
    assert(c:list_tables({}))
    t.eq(host.requests[2].url, "https://dynamodb.us-east-1.amazonaws.com/")
    local c2, host2 = client(DynamoDB, { json_res(200, "{}") }, {
      region = false,
      credentials = aws_credentials.static({
        access_key_id = "AKID",
        secret_access_key = "s",
        region = "ap-south-1",
      }),
    })
    assert(c2:list_tables({}))
    t.eq(host2.requests[1].url, "https://dynamodb.ap-south-1.amazonaws.com/")
  end)

  t.it("no region anywhere is MissingRegion, before any request", function()
    local c, host = client(DynamoDB, {}, {
      region = false,
      credentials = aws_credentials.static({ access_key_id = "AKID", secret_access_key = "s" }),
    })
    local out, err = c:list_tables({})
    t.fails_with("MissingRegion", out, err)
    t.eq(#host.requests, 0)
  end)

  t.it("a custom endpoint (option or AWS_ENDPOINT_URL) replaces the rules", function()
    local c, host = client(SQS, { json_res(200, "{}") }, { endpoint = "http://localhost:4566/" })
    assert(c:list_queues({}))
    t.eq(host.requests[1].url, "http://localhost:4566/")
    local c2, host2 = client(SQS, { json_res(200, "{}") }, {
      env = { AWS_ENDPOINT_URL = "http://127.0.0.1:9324" },
    })
    assert(c2:list_queues({}))
    t.eq(host2.requests[1].url, "http://127.0.0.1:9324/")
  end)

  t.it("fills an idempotency token the caller did not set (UUID v4 from host.random)", function()
    local EC2 = require("aws.ec2")
    local c, host = client(EC2, {
      {
        status = 200,
        headers = { ["content-type"] = "text/xml" },
        body = "<RunInstancesResponse/>",
      },
      {
        status = 200,
        headers = { ["content-type"] = "text/xml" },
        body = "<RunInstancesResponse/>",
      },
    })
    assert(c:run_instances({ MinCount = 1, MaxCount = 1, ImageId = "ami-1" }))
    local token = string.match(host.requests[1].body, "ClientToken=([^&]+)")
    t.truthy(token, "a ClientToken")
    t.match(token, "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
    assert(c:run_instances({ MinCount = 1, MaxCount = 1, ImageId = "ami-1", ClientToken = "mine" }))
    t.match(host.requests[2].body, "ClientToken=mine", true)
  end)

  t.it("a bad input is InvalidInput before any request (a label that is empty)", function()
    local Lambda = require("aws.lambda")
    local c, host = client(Lambda, {})
    local out, err = c:get_function({ FunctionName = "" })
    t.fails_with("InvalidInput", out, err)
    t.eq(#host.requests, 0)
  end)
end)

t.describe("aws client: trace propagation (core telemetry-xray.ts)", function()
  t.it("sends X-Amzn-Trace-Id continuing the parent trace, no traceparent", function()
    local trace = require("distilled.trace")
    local parent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    local host = testing.host({ responses = { json_res(200, "{}") } })
    local tracer = trace.new({
      exporter = function()
        return true
      end,
      parent = parent,
      host = host,
    })
    local c =
      DynamoDB.new({ region = "us-east-1", credentials = CREDS, host = host, tracer = tracer })
    assert(c:list_tables({}))
    local h = host.requests[1].headers
    t.match(
      h["x-amzn-trace-id"],
      "^Root=1%-4bf92f35%-77b34da6a3ce929d0e0e4736;Parent=%x+;Sampled=1$"
    )
    t.eq(h["traceparent"], nil)
    t.eq(
      require("distilled.aws.protocol").xray_header(string.rep("a", 32), string.rep("b", 16), false),
      "Root=1-aaaaaaaa-" .. string.rep("a", 24) .. ";Parent=" .. string.rep("b", 16) .. ";Sampled=0"
    )
  end)
end)

t.describe("aws client: pagination", function()
  t.it("awsJson: a string token, then a map token (DynamoDB Scan's LastEvaluatedKey)", function()
    local c, host = client(DynamoDB, {
      json_res(200, '{"TableNames":["a","b"],"LastEvaluatedTableName":"b"}'),
      json_res(200, '{"TableNames":["c"]}'),
      json_res(200, '{"Items":[{"id":{"S":"1"}}],"LastEvaluatedKey":{"id":{"S":"1"}}}'),
      json_res(200, '{"Items":[{"id":{"S":"2"}}]}'),
    })
    local names = {}
    local it = c:list_tables_items({})
    for name in it do
      names[#names + 1] = name
    end
    t.eq(it.err, nil)
    t.same(names, { "a", "b", "c" })
    t.same(json.decode(host.requests[2].body), { ExclusiveStartTableName = "b" })
    local ids = {}
    local it2 = c:scan_items({ TableName = "t" })
    for item in it2 do
      ids[#ids + 1] = item.id.S
    end
    t.eq(it2.err, nil)
    t.same(ids, { "1", "2" })
    t.same(json.decode(host.requests[4].body).ExclusiveStartKey, { id = { S = "1" } })
  end)

  t.it("ec2Query (NextToken in the form) and restJson1 (Marker in the query)", function()
    local EC2 = require("aws.ec2")
    local xml = { ["content-type"] = "text/xml" }
    local c, host = client(EC2, {
      {
        status = 200,
        headers = xml,
        body = "<R><reservationSet><item><reservationId>r-1</reservationId></item></reservationSet>"
          .. "<nextToken>tok 2</nextToken></R>",
      },
      {
        status = 200,
        headers = xml,
        body = "<R><reservationSet><item><reservationId>r-2</reservationId></item></reservationSet></R>",
      },
    })
    local ids = {}
    for r in c:describe_instances_items({}) do
      ids[#ids + 1] = r.ReservationId
    end
    t.same(ids, { "r-1", "r-2" })
    t.match(host.requests[2].body, "NextToken=tok%202", true)
    local Lambda = require("aws.lambda")
    local jh = { ["content-type"] = "application/json" }
    local l, lhost = client(Lambda, {
      {
        status = 200,
        headers = jh,
        body = '{"Functions":[{"FunctionName":"f"}],"NextMarker":"m/2"}',
      },
      { status = 200, headers = jh, body = '{"Functions":[{"FunctionName":"g"}]}' },
    })
    local fns = {}
    for f in l:list_functions_items({}) do
      fns[#fns + 1] = f.FunctionName
    end
    t.same(fns, { "f", "g" })
    t.match(lhost.requests[2].url, "Marker=m%2F2", true)
  end)
end)

t.describe("aws client: long lists (gopher-lua's table.concat limit)", function()
  t.it("4,000 ec2Query list items and a 3,000-record restXml batch serialise", function()
    local EC2 = require("aws.ec2")
    local c, host = client(EC2, {
      { status = 200, headers = { ["content-type"] = "text/xml" }, body = "<R/>" },
    })
    local ids = {}
    for i = 1, 4000 do
      ids[i] = "i-" .. i
    end
    assert(c:describe_instances({ InstanceIds = ids }))
    t.match(host.requests[1].body, "InstanceId.4000=i-4000", true)
    local Route53 = require("aws.route_53")
    local r, rhost = client(Route53, {
      {
        status = 200,
        headers = { ["content-type"] = "text/xml" },
        body = "<ChangeResourceRecordSetsResponse><ChangeInfo><Id>c</Id><Status>PENDING</Status>"
          .. "<SubmittedAt>2023-11-14T22:13:20Z</SubmittedAt></ChangeInfo>"
          .. "</ChangeResourceRecordSetsResponse>",
      },
    })
    local records = {}
    for i = 1, 3000 do
      records[i] = { Value = "192.0.2." .. (i % 250) }
    end
    local out, err = r:change_resource_record_sets({
      HostedZoneId = "Z1",
      ChangeBatch = {
        Changes = {
          {
            Action = "UPSERT",
            ResourceRecordSet = { Name = "a.", Type = "A", TTL = 60, ResourceRecords = records },
          },
        },
      },
    })
    t.truthy(out, err and err.message)
    t.eq(out.ChangeInfo.SubmittedAt, 1700000000)
    local _, n = string.gsub(rhost.requests[1].body, "<ResourceRecord>", "")
    t.eq(n, 3000)
  end)
end)

t.describe("aws client: errors and retry", function()
  t.it("a throttling error is retried with backoff, and SigV4 signs every attempt", function()
    local c, host = client(DynamoDB, {
      json_res(
        400,
        '{"__type":"com.amazon.coral.availability#ThrottlingException","message":"Rate exceeded"}'
      ),
      json_res(200, '{"TableNames":[]}'),
    })
    local out, err = c:list_tables({})
    t.truthy(out, err and err.message)
    t.eq(#host.requests, 2)
    t.eq(#host.sleeps, 1)
    t.truthy(host.sleeps[1] > 0, "a backoff")
    t.truthy(header(host.requests[2], "authorization"), "the retry is signed")
  end)

  t.it("a transient error (ServiceUnavailable) is retried until the attempts run out", function()
    local responses = {}
    for i = 1, 10 do
      responses[i] = json_res(503, '{"__type":"ServiceUnavailable","message":"busy"}')
    end
    local c, host = client(DynamoDB, responses)
    local out, err = c:list_tables({})
    t.fails_with("ServiceUnavailable", out, err)
    t.truthy(#host.requests > 1, "retried")
    t.eq(#host.sleeps, #host.requests - 1)
  end)

  t.it("a 5xx with no body and no code is a ParseError, not retried (as Distilled)", function()
    local c, host = client(DynamoDB, { { status = 503, headers = {}, body = "" } })
    local out, err = c:list_tables({})
    t.fails_with("ParseError", out, err)
    t.match(err.message, "No error code found", true)
    t.eq(#host.requests, 1)
  end)

  t.it("a declared error is its class, with its fields and categories, not retried", function()
    local c, host = client(DynamoDB, {
      json_res(
        400,
        '{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",'
          .. '"message":"The conditional request failed","Item":{"id":{"S":"u-1"}}}'
      ),
    })
    local out, err = c:put_item({ TableName = "t", Item = { id = { S = "u-1" } } })
    t.fails_with("ConditionalCheckFailedException", out, err)
    t.eq(err.message, "The conditional request failed")
    t.same(err.Item, { id = { S = "u-1" } })
    t.eq(err.status, 400)
    t.eq(#host.requests, 1)
  end)

  t.it("an undeclared code is UnknownAwsError with the code and the service", function()
    local c = client(DynamoDB, {
      json_res(
        400,
        '{"__type":"com.amazonaws.dynamodb.v20120810#SomethingNewException","message":"new"}'
      ),
    })
    local out, err = c:list_tables({})
    t.fails_with("UnknownAwsError", out, err)
    t.eq(err.code, "SomethingNewException")
    t.eq(err.service, "DynamoDB")
  end)

  t.it("an awsQuery-compatible error code (x-amzn-query-error) finds the class", function()
    local c = client(SQS, {
      json_res(
        400,
        '{"__type":"com.amazonaws.sqs#QueueDoesNotExist","message":"no such queue"}',
        { ["x-amzn-query-error"] = "AWS.SimpleQueueService.NonExistentQueue;Sender" }
      ),
    })
    local out, err = c:get_queue_url({ QueueName = "nope" })
    t.fails_with("QueueDoesNotExist", out, err)
  end)

  t.it("an expired credential is resolved again before the call", function()
    local calls = 0
    local source = function()
      calls = calls + 1
      if calls == 1 then
        return { access_key_id = "OLD", secret_access_key = "s", expiration = 1700000000 - 10 }
      end
      return { access_key_id = "NEW", secret_access_key = "s", expiration = 1700000000 + 3600 }
    end
    local c, host = client(DynamoDB, { json_res(200, "{}") }, { credentials = source })
    local out, err = c:list_tables({})
    t.truthy(out, err and err.message)
    t.eq(#host.requests, 1)
    t.match(header(host.requests[1], "authorization"), "Credential=NEW/", true)
  end)

  t.it("never puts the secret key or the session token in an error", function()
    local c = client(DynamoDB, { json_res(400, "not json at all") }, {
      credentials = aws_credentials.static({
        access_key_id = "AKID",
        secret_access_key = "SUPERSECRETKEY",
        session_token = "SESSIONTOKENVALUE",
      }),
    })
    local out, err = c:list_tables({})
    t.truthy(out == nil and err, "fails")
    local text = json.encode(err) or tostring(err.message)
    t.no_match(text, "SUPERSECRETKEY", true)
    t.no_match(text, "SESSIONTOKENVALUE", true)
  end)
end)

t.describe("aws client: SigV2, bearer and gzip services", function()
  t.it("SimpleDB signs with SigV2 in the body (the signature Distilled computes)", function()
    local SimpleDB = require("aws.simpledb")
    local c, host = client(SimpleDB, {
      {
        status = 200,
        headers = { ["content-type"] = "text/xml" },
        body = "<SelectResponse><SelectResult></SelectResult></SelectResponse>",
      },
    })
    assert(c:select({ SelectExpression = "select * from d" }))
    local body = host.requests[1].body
    t.match(body, "SignatureVersion=2&", true)
    t.match(body, "Timestamp=2023-11-14T22%3A13%3A20Z", true)
    -- verify/conform/ref/aws/outcomes.json, simpledb.select (Distilled's sigv2.ts)
    local ref =
      json.decode(assert(io.open(t.root .. "/verify/conform/ref/aws/outcomes.json")):read("*a"))
    local want
    for _, r in ipairs(ref) do
      if r.id == "simpledb.select" then
        want = string.match(r.request.body, "Signature=([^&]+)")
      end
    end
    t.eq(string.match(body, "Signature=([^&]+)"), want)
    t.eq(header(host.requests[1], "authorization"), nil)
  end)

  t.it("a bearer-token service sends the token, no SigV4", function()
    local CodeCatalyst = require("aws.codecatalyst")
    t.truthy(CodeCatalyst.option_specs.token, "a token option")
    local c, host = client(CodeCatalyst, {
      { status = 200, headers = { ["content-type"] = "application/json" }, body = '{"items":[]}' },
    }, { token = "tok-123" })
    assert(c:list_spaces({}))
    t.eq(header(host.requests[1], "authorization"), "Bearer tok-123")
  end)

  t.it("CloudWatch PutMetricData gzips a body of 10 KiB or more", function()
    local CloudWatch = require("aws.cloudwatch")
    local data = {}
    for i = 1, 200 do
      data[i] = { MetricName = "metric-" .. i, Value = i, Unit = "Count" }
    end
    local c, host = client(CloudWatch, {
      { status = 200, headers = { ["content-type"] = "application/x-amz-json-1.0" }, body = "{}" },
      { status = 200, headers = { ["content-type"] = "application/x-amz-json-1.0" }, body = "{}" },
    })
    assert(c:put_metric_data({ Namespace = "app", MetricData = data }))
    local req = host.requests[1]
    t.eq(header(req, "content-encoding"), "gzip")
    t.eq(string.sub(req.body, 1, 3), "\31\139\8")
    assert(c:put_metric_data({ Namespace = "app", MetricData = { data[1] } }))
    t.eq(header(host.requests[2], "content-encoding"), nil)
  end)
end)
