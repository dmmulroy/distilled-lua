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
  ["smithy.api#http"] = { handled = "ops.lua: method, uri, code, contentType, bodyMediaType" },
  ["smithy.api#paginated"] = { handled = "ops.lua: pagination, validated against members" },
  ["smithy.api#documentation"] = { handled = "types.lua and README.md: descriptions" },
  ["com.distilled.openapi#contentType"] = {
    handled = "ops.lua: op.content_type (the same value as smithy.api#http contentType)",
  },
  ["com.distilled.openapi#streamWhen"] = {
    fail = "streaming operations are not supported by distilled-lua",
  },
  ["com.distilled.grpc#serverStreaming"] = {
    fail = "streaming operations are not supported by distilled-lua",
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

-- Namespaces where an unknown trait fails generation.
traits.GUARDED = {
  "smithy.api#http",
  "com.distilled.openapi#",
  "com.distilled.telemetry#",
  "com.distilled.grpc#",
  "distilled.",
}

--- traits.lookup(id) -> entry | nil
function traits.lookup(id)
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
