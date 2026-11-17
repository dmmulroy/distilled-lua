-- Every operation of every generated AWS client, called end to end: a synthesized
-- minimal input (verify/lib/gen_input.lua) through the client, the AWS protocol
-- (idempotency tokens, serialisation, checksums, endpoint rules, SigV4 / SigV2 / bearer)
-- and a scripted transport that answers with a protocol-shaped empty success, then a
-- typed error. Nothing may raise: a call either returns a value or `nil, err`.
--
--   lua verify/lib/aws_call_all.lua <root> [service-pattern]
--   rex do verify/lib/aws_call_all.lua root=<root> [only=<pattern>]
--
-- Counts: ok (decoded), error (an expected `nil, err`, by tag), raised (a bug). An
-- error on the success response is a finding only when it is not the modelled refusal
-- of the synthesized input (InvalidInput for an empty label, a host label, ...).
local rex_api = rawget(_G, "rex")
local root, only
if rex_api then
  local a = rawget(rex_api, "args") or {}
  root, only = a.root, a.only
else
  root, only = arg[1], arg[2]
end
root = root or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local compat = require("distilled.compat")
local testing = require("distilled.testing")
local synth = require("verify.lib.gen_input")
local aws_credentials = require("distilled.aws.credentials")

local SUCCESS = {
  awsJson1_0 = { headers = { ["content-type"] = "application/x-amz-json-1.0" }, body = "{}" },
  awsJson1_1 = { headers = { ["content-type"] = "application/x-amz-json-1.1" }, body = "{}" },
  restJson1 = { headers = { ["content-type"] = "application/json" }, body = "{}" },
  awsQuery = { headers = { ["content-type"] = "text/xml" }, body = "<R><XResult></XResult></R>" },
  ec2Query = { headers = { ["content-type"] = "text/xml" }, body = "<R></R>" },
  restXml = { headers = { ["content-type"] = "text/xml" }, body = "" },
}
local FAILURE = {
  awsJson1_0 = '{"__type":"ThrottlingException","message":"slow down"}',
  awsJson1_1 = '{"__type":"ThrottlingException","message":"slow down"}',
  restJson1 = '{"__type":"ThrottlingException","message":"slow down"}',
  awsQuery = "<ErrorResponse><Error><Code>Throttling</Code><Message>slow down</Message></Error></ErrorResponse>",
  ec2Query = "<Response><Errors><Error><Code>RequestLimitExceeded</Code><Message>slow down</Message></Error></Errors></Response>",
  restXml = "<ErrorResponse><Error><Code>Throttling</Code><Message>slow down</Message></Error></ErrorResponse>",
}

local index = require("aws")
local stats =
  { services = 0, ops = 0, ok = 0, errors = {}, raised = 0, unsupported = 0, expected = 0 }
local findings = {}

local function note(kind, what)
  findings[#findings + 1] = kind .. " " .. what
end

for _, name in ipairs(index.services) do
  if not only or string.find(name, only) then
    stats.services = stats.services + 1
    local class = require("aws." .. name)
    local service = require("aws." .. name .. ".service")
    -- the protocol the client was generated with (distilled.aws.protocol keeps its name)
    local protocol = class.protocol and class.protocol.name
    local names = {}
    for op_name in pairs(service.ops) do
      names[#names + 1] = op_name
    end
    table.sort(names)
    for _, op_name in ipairs(names) do
      local op = service.ops[op_name]
      stats.ops = stats.ops + 1
      local input = synth.input(op, service.shapes) or {}
      for _, phase in ipairs({ "success", "failure" }) do
        local host = testing.host({})
        host.transport = function()
          local proto = protocol
          if phase == "success" then
            local s = SUCCESS[proto]
            return { status = 200, headers = s.headers, body = s.body }
          end
          return { status = 400, headers = SUCCESS[proto].headers, body = FAILURE[proto] }
        end
        local options = {
          region = "us-east-1",
          credentials = aws_credentials.static({
            access_key_id = "AKIDEXAMPLE",
            secret_access_key = "secret",
          }),
          host = host,
          retry = "none",
        }
        if class.option_specs and class.option_specs.token then
          options.token = "bearer-token"
        end
        local client = class.new(options)
        local ok, v, err = compat.pcall(client[op_name], client, input)
        if not ok then
          stats.raised = stats.raised + 1
          note("RAISED", name .. "." .. op_name .. " (" .. phase .. "): " .. tostring(v))
        elseif v == nil then
          local tag = err and err.tag or "?"
          if op.unsupported then
            stats.unsupported = stats.unsupported + 1
          else
            stats.errors[phase .. " " .. tag] = (stats.errors[phase .. " " .. tag] or 0) + 1
            -- expected: InvalidInput (the synthesized input breaks a label rule), and
            -- EndpointError where the rules validate an input (a KVS ARN): the
            -- modelled refusal of "x". RequestLimitExceeded on an EC2 operation that
            -- does not declare it is UnknownAwsError, as in Distilled (not in
            -- COMMON_ERRORS).
            -- event streams (task 31): a bidirectional operation is refused by the plain
            -- call (SdkError: use its stream), and an output stream given the fake
            -- success body (not event-stream frames) is a ParseError
            local stream = op.stream
            local expected = tag == "InvalidInput"
              or tag == "EndpointError"
              or (tag == "UnknownAwsError" and err.code == "RequestLimitExceeded")
              or (stream and stream.input and tag == "SdkError")
              or (stream and phase == "success" and tag == "ParseError")
            if expected then
              stats.expected = stats.expected + 1
            elseif phase == "success" then
              note("ERROR", name .. "." .. op_name .. ": " .. tag .. ": " .. tostring(err.message))
            elseif phase == "failure" and not err.throttling then
              note(
                "NOT-THROTTLING",
                name .. "." .. op_name .. ": " .. tag .. ": " .. tostring(err.message)
              )
            end
          end
        else
          if phase == "success" then
            stats.ok = stats.ok + 1
          else
            note("OK-ON-ERROR", name .. "." .. op_name)
          end
        end
      end
    end
  end
end

for i, f in ipairs(findings) do
  if i <= 60 then
    print(f)
  end
end
local keys = {}
for k in pairs(stats.errors) do
  keys[#keys + 1] = k
end
table.sort(keys)
for _, k in ipairs(keys) do
  print(string.format("  %-40s %d", k, stats.errors[k]))
end
local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
print(
  string.format(
    "aws call-all [%s]: %d services, %d ops, %d ok, %d raised, %d acknowledged unsupported,"
      .. " %d expected refusals, %d findings",
    runtime,
    stats.services,
    stats.ops,
    stats.ok,
    stats.raised,
    stats.unsupported,
    stats.expected,
    #findings
  )
)
if rex_api then
  if stats.raised > 0 or #findings > 0 then
    error("aws call-all: " .. stats.raised .. " raised, " .. #findings .. " findings")
  end
  return { ops = stats.ops, ok = stats.ok, raised = stats.raised }
end
if stats.raised > 0 or #findings > 0 then
  os.exit(1)
end
