-- Every trait id the generator knows, with where it is handled or why it is ignored.
--
-- `model.load` audits every trait on every shape and member against this table. An id
-- that is not here fails generation when it is in a guarded namespace (the HTTP binding
-- traits, Distilled's own traits), so a new model feature cannot be dropped silently;
-- anything else is a warning printed by the CLI.
--
-- Entries: `handled = "<file>: <what>"`, `ignored = "<why>"`, or `fail = "<why>"` for
-- known traits the runtime cannot honour (generation stops with that reason).
local traits = {}

traits.TABLE = {
  -- operations
  ["smithy.api#http"] = {
    handled = "ops.lua: method, uri, code, contentType, bodyMediaType, and the extensions"
      .. " baseUrl, server, accept, rawDownload, apiVersion (op.base_url, op.server,"
      .. " op.accept, op.raw_download, op.api_version)",
  },
  ["com.tencentcloud#action"] = {
    handled = "rpc.lua: op.rpc (service, version, action) when the provider spec has rpc",
  },
  ["smithy.api#paginated"] = { handled = "ops.lua: pagination, validated against members" },
  ["smithy.api#documentation"] = { handled = "types.lua and README.md: descriptions" },
  ["com.distilled.openapi#apiVersion"] = {
    handled = "azure.lua: op.api_version (with the Azure protocol only)",
  },
  ["com.distilled.openapi#contentType"] = {
    handled = "ops.lua: op.content_type (the same value as smithy.api#http contentType)",
  },
  -- Streaming (traits.STREAMING): emitted only with allow_unsupported = { "streaming" }.
  ["com.distilled.openapi#streamWhen"] = {
    handled = "ops.lua: streaming; the plain call is emitted (it keeps the operation's"
      .. " output, as in Distilled), the stream variant is not",
  },
  ["com.distilled.grpc#serverStreaming"] = {
    handled = 'ops.lua: streaming; op.unsupported = "streaming" (SdkError at call time)',
  },
  ["com.distilled.grpc#clientStreaming"] = {
    handled = 'ops.lua: streaming; op.unsupported = "streaming" (SdkError at call time)',
  },
  ["distilled.errors#bodies"] = {
    handled = "types.lua: the documented body types of an error class (runtime keeps the"
      .. " parsed body as is; key mapping is a no-op when member names equal wire names)",
  },
  ["distilled.retry#policy"] = { handled = "ops.lua: op.retry (service trait under the op's)" },
  ["com.distilled.telemetry#operation"] = { handled = "ops.lua: op.span" },
  ["com.distilled.telemetry#service"] = { handled = "ops.lua: service.telemetry" },
  ["com.distilled.telemetry#attributes"] = { handled = "ops.lua: op.span input/output rules" },

  -- members
  ["smithy.api#httpLabel"] = { handled = "shapes.lua: bind = label (greedy from the URI)" },
  ["smithy.api#httpQuery"] = { handled = "shapes.lua: bind = query, wire = trait value" },
  ["smithy.api#httpHeader"] = { handled = "shapes.lua: bind = header, wire = trait value" },
  ["smithy.api#httpPayload"] = { handled = "shapes.lua: bind = payload" },
  ["smithy.api#httpResponseCode"] = { handled = "shapes.lua: bind = status" },
  ["smithy.api#httpError"] = { handled = "errors.lua: categories (errorCategories)" },
  ["smithy.api#httpQueryParams"] = {
    fail = "a map of query parameters has no binding in the member contract",
  },
  ["smithy.api#httpPrefixHeaders"] = {
    fail = "prefix headers have no binding in the member contract",
  },
  ["smithy.api#httpChecksumRequired"] = { fail = "request checksums are not supported" },
  ["smithy.api#httpApiKeyAuth"] = {
    ignored = "auth comes from the provider spec, not the model",
  },
  ["smithy.api#httpBearerAuth"] = {
    ignored = "auth comes from the provider spec, not the model",
  },
  ["smithy.api#httpBasicAuth"] = {
    ignored = "auth comes from the provider spec, not the model",
  },
  ["smithy.api#httpDigestAuth"] = {
    ignored = "auth comes from the provider spec, not the model",
  },
  ["smithy.api#jsonName"] = { handled = "shapes.lua: wire name of a body member" },
  ["smithy.api#required"] = { handled = "shapes.lua: required" },
  ["smithy.api#default"] = {
    handled = "shapes.lua: a member with a default is required in response-only shapes",
  },
  ["smithy.api#sensitive"] = { handled = "shapes.lua: sensitive (member) or node.sensitive" },
  ["smithy.api#enumValue"] = { handled = "shapes.lua: enum values" },
  ["com.distilled.openapi#nullable"] = { handled = "shapes.lua: nullable" },
  ["com.distilled.openapi#rawResponse"] = {
    handled = "ops.lua: the output is the member's value (output_raw)",
  },
  ["com.distilled.openapi#additionalProperties"] = { handled = "shapes.lua: open = true" },
  ["distilled.protocols#stringEncoded"] = {
    handled = "shapes.lua: string_encoded (set by the boolean-string-enum pass)",
  },

  -- errors
  ["smithy.api#error"] = { handled = "errors.lua: the shape is an error class" },
  ["smithy.api#retryable"] = { handled = "errors.lua: retryable, throttling, categories" },
  ["com.distilled.openapi#errorMatchers"] = {
    handled = "errors.lua: matchers (regexes compiled at generation time)",
  },
  ["distilled.errors#categories"] = { handled = "errors.lua: extra categories" },

  -- ignored on purpose
  ["smithy.api#input"] = { ignored = "marks an operation input; the operation says so already" },
  ["smithy.api#output"] = {
    ignored = "marks an operation output; the operation says so already",
  },
  ["smithy.api#title"] = { ignored = "the service title; the provider spec names the client" },
  ["smithy.api#suppress"] = { ignored = "Smithy validator suppressions" },
  ["smithy.api#deprecated"] = { ignored = "no deprecation surface in the Lua client" },
  ["smithy.api#tags"] = { ignored = "documentation grouping only" },
  ["smithy.api#examples"] = { ignored = "documentation only" },
  ["smithy.api#externalDocumentation"] = { ignored = "documentation only" },
  ["smithy.api#readonly"] = { ignored = "no behaviour attached in the runtime" },
  ["smithy.api#idempotent"] = { ignored = "no behaviour attached in the runtime" },
  ["smithy.api#idempotencyToken"] = { ignored = "callers pass their own token" },
  ["smithy.api#length"] = { ignored = "constraint traits are not validated client-side" },
  ["smithy.api#range"] = { ignored = "constraint traits are not validated client-side" },
  ["smithy.api#pattern"] = { ignored = "constraint traits are not validated client-side" },
  ["smithy.api#uniqueItems"] = { ignored = "constraint traits are not validated client-side" },
  ["smithy.api#timestampFormat"] = {
    ignored = "timestamps are strings on the wire and in Lua (Distilled's JSON prelude)",
  },
  ["smithy.api#mediaType"] = { ignored = "a blob is bytes whatever its media type" },
}

-- AWS models (gen/aws.lua, task 17): consulted before TABLE when the model is an AWS
-- model, so the HTTP traits the AWS runtime honours (httpQueryParams, prefix headers,
-- checksums) are handled there and fail elsewhere.
local function aws_handled(what)
  return { handled = "gen/aws.lua + lua/distilled/aws: " .. what }
end
local function aws_ignored(why)
  return { ignored = why }
end
traits.AWS = {
  ["aws.api#service"] = aws_handled("sdkId, endpointPrefix (service facts)"),
  ["aws.api#arn"] = aws_ignored("resource ARN templates: documentation"),
  ["aws.api#arnReference"] = aws_ignored("documentation"),
  ["aws.api#clientDiscoveredEndpoint"] = aws_ignored(
    "endpoint discovery is optional; the regional endpoint is used (as Distilled does)"
  ),
  ["aws.api#clientEndpointDiscovery"] = aws_ignored("endpoint discovery: see above"),
  ["aws.api#controlPlane"] = aws_ignored("no behaviour attached"),
  ["aws.api#dataPlane"] = aws_ignored("no behaviour attached"),
  ["aws.api#data"] = aws_ignored("data classification: documentation"),
  ["aws.api#tagEnabled"] = aws_ignored("documentation"),
  ["aws.api#taggable"] = aws_ignored("documentation"),
  ["aws.auth#sigv4"] = aws_handled("SigV4 signing name (distilled.sigv4)"),
  ["aws.auth#sigv4a"] = aws_handled("noted; an endpoint that requires SigV4A fails with SdkError"),
  ["aws.auth#unsignedPayload"] = aws_handled("op.aws.unsigned_payload: UNSIGNED-PAYLOAD"),
  ["aws.auth#sigv2"] = aws_handled("noted (SimpleDB); SigV2 is not implemented"),
  ["aws.codegen#errorTag"] = aws_handled("the error class tag (the wire code)"),
  ["aws.codegen#synthetic"] = aws_handled("synthetic error matchers (code + message)"),
  ["aws.customizations#s3UnwrappedXmlOutput"] = aws_handled("op.aws.unwrapped_output"),
  ["aws.endpoints#dualStackOnlyEndpoints"] = aws_ignored("covered by the endpoint rules"),
  ["aws.endpoints#rulesBasedEndpoints"] = aws_ignored("covered by the endpoint rules"),
  ["aws.endpoints#standardPartitionalEndpoints"] = aws_ignored("covered by the endpoint rules"),
  ["aws.endpoints#standardRegionalEndpoints"] = aws_ignored("covered by the endpoint rules"),
  ["aws.protocols#restJson1"] = aws_handled("protocol restJson1"),
  ["aws.protocols#awsJson1_0"] = aws_handled("protocol awsJson1_0"),
  ["aws.protocols#awsJson1_1"] = aws_handled("protocol awsJson1_1"),
  ["aws.protocols#awsQuery"] = aws_handled("protocol awsQuery"),
  ["aws.protocols#ec2Query"] = aws_handled("protocol ec2Query"),
  ["aws.protocols#restXml"] = aws_handled("protocol restXml"),
  ["aws.protocols#awsQueryCompatible"] = aws_handled("x-amzn-query-mode: true"),
  ["aws.protocols#awsQueryError"] = aws_handled("the error's query code and status"),
  ["aws.protocols#ec2QueryName"] = aws_handled("member.ec2_name"),
  ["aws.protocols#httpChecksum"] = aws_handled("op.aws.checksum (Content-MD5, x-amz-checksum-*)"),
  ["smithy.api#httpChecksumRequired"] = aws_handled("op.aws.checksum.required"),
  ["smithy.api#httpQueryParams"] = aws_handled("bind = query_params"),
  ["smithy.api#httpPrefixHeaders"] = aws_handled("bind = prefix_headers"),
  ["smithy.api#idempotencyToken"] = aws_handled("a UUID v4 from host.random when absent"),
  ["smithy.api#timestampFormat"] = aws_handled("member.ts, node.format"),
  ["smithy.api#mediaType"] = aws_handled("node.media_type (base64 headers, payload type)"),
  ["smithy.api#xmlName"] = aws_handled("member.xml_name, node.xml_name, item/key/value names"),
  ["smithy.api#xmlFlattened"] = aws_handled("member.flat"),
  ["smithy.api#xmlAttribute"] = aws_handled("member.attr"),
  ["smithy.api#xmlNamespace"] = aws_handled("member.xmlns, the service's namespace"),
  ["smithy.api#hostLabel"] = aws_handled("host prefix labels"),
  ["smithy.api#endpoint"] = aws_handled("op.aws.host_prefix"),
  ["smithy.api#streaming"] = aws_handled(
    "a streaming blob is a buffered string; an event stream operation is unsupported"
  ),
  ["smithy.api#eventHeader"] = aws_ignored("event streams are unsupported"),
  ["smithy.api#eventPayload"] = aws_ignored("event streams are unsupported"),
  ["smithy.api#requiresLength"] = aws_ignored("bodies are buffered strings: the length is known"),
  ["smithy.api#requestCompression"] = aws_handled(
    "op.aws.gzip: gzip bodies of at least 10 KiB (aws/gzip.lua)"
  ),
  ["smithy.api#auth"] = aws_handled("an empty list: op.aws.optional_auth"),
  ["smithy.api#optionalAuth"] = aws_handled("op.aws.optional_auth"),
  ["smithy.api#clientOptional"] = aws_handled("not required on input"),
  ["smithy.api#addedDefault"] = aws_ignored("a default added later: no behaviour"),
  ["smithy.api#default"] = aws_ignored("defaults are the service's; members stay optional"),
  ["smithy.api#sparse"] = aws_handled("S.nullable list items / map values: nulls kept"),
  ["smithy.api#enum"] = aws_ignored("a string with enum values: the values are documentation"),
  ["smithy.api#cors"] = aws_ignored("browser CORS: no behaviour in Lua"),
  ["smithy.api#private"] = aws_ignored("no behaviour attached"),
  ["smithy.api#unstable"] = aws_ignored("no behaviour attached"),
  ["smithy.api#recommended"] = aws_ignored("no behaviour attached"),
  ["smithy.api#references"] = aws_ignored("resource references: documentation"),
  ["smithy.api#resourceIdentifier"] = aws_ignored("resource binding: documentation"),
  ["smithy.api#nestedProperties"] = aws_ignored("resource properties: documentation"),
  ["smithy.api#notProperty"] = aws_ignored("resource properties: documentation"),
  ["smithy.api#property"] = aws_ignored("resource properties: documentation"),
  ["smithy.api#noReplace"] = aws_ignored("resource lifecycle: documentation"),
  ["smithy.protocols#rpcv2Cbor"] = aws_ignored("not implemented; Distilled skips it too"),
  ["smithy.rules#endpointRuleSet"] = aws_handled("endpoints.lua, distilled.aws.endpoint"),
  ["smithy.rules#endpointBdd"] = aws_ignored("the same rules as endpointRuleSet, as a BDD"),
  ["smithy.rules#endpointTests"] = aws_handled("verify/lib/aws_endpoint_tests.lua"),
  ["smithy.rules#contextParam"] = aws_handled("member.context_param"),
  ["smithy.rules#staticContextParams"] = aws_handled("op.aws.static_params"),
  ["smithy.rules#clientContextParams"] = aws_ignored("client endpoint settings: defaults used"),
  ["smithy.rules#operationContextParams"] = aws_ignored("Distilled does not read them either"),
  ["smithy.test#smokeTests"] = aws_ignored("tests, not behaviour"),
  ["smithy.waiters#waitable"] = aws_ignored("waiters are not generated"),
  ["com.distilled.aws#event"] = aws_ignored("event payload types (ses-events), no operations"),
}
for _, id in ipairs({
  "aws.cloudformation#cfnAdditionalIdentifier",
  "aws.cloudformation#cfnExcludeProperty",
  "aws.cloudformation#cfnMutability",
  "aws.cloudformation#cfnName",
  "aws.cloudformation#cfnResource",
  "aws.iam#actionPermissionDescription",
  "aws.iam#conditionKeyValue",
  "aws.iam#conditionKeys",
  "aws.iam#defineConditionKeys",
  "aws.iam#disableConditionKeyInference",
  "aws.iam#iamAction",
  "aws.iam#iamResource",
  "aws.iam#requiredActions",
  "aws.iam#serviceResolvedConditionKeys",
  "aws.iam#supportedPrincipalTypes",
}) do
  traits.AWS[id] = aws_ignored("CloudFormation / IAM metadata: documentation")
end

-- Streaming traits: trait id -> true when only the stream variant needs streaming (the
-- operation's plain call still works: streamWhen), false when every call streams.
traits.STREAMING = {
  ["com.distilled.openapi#streamWhen"] = true,
  ["com.distilled.grpc#serverStreaming"] = false,
  ["com.distilled.grpc#clientStreaming"] = false,
}

-- Namespaces where an unknown trait fails generation.
traits.GUARDED = {
  "smithy.api#http",
  "com.distilled.openapi#",
  "com.distilled.telemetry#",
  "com.distilled.grpc#",
  "distilled.",
  "aws.",
  "smithy.rules#",
}

--- traits.lookup(id [, aws]) -> entry | nil (aws: the model is an AWS model)
function traits.lookup(id, aws)
  if aws and traits.AWS[id] then
    return traits.AWS[id]
  end
  return traits.TABLE[id]
end

--- traits.guarded(id) -> boolean
function traits.guarded(id)
  for _, prefix in ipairs(traits.GUARDED) do
    if string.sub(id, 1, #prefix) == prefix then
      return true
    end
  end
  return false
end

return traits
