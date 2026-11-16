-- A small Smithy JSON model for the generator specs (spec/gen_*_spec.lua). It touches
-- every shape type and every trait the generator handles, in a few operations, and stays
-- small enough to generate under gopher-lua in milliseconds.
--
--   local fx = require("verify.lib.gen_fixture")
--   fx.text()                                  -- the model as JSON text
--   fx.text({ extra = '"ex.api#X": {...}', replace = { { "old", "new" } } })
--   fx.model(opts) -> Model | nil, err         -- gen.model.from_text(fx.text(opts))
--   fx.provider(overrides) -> provider spec table
local fx = {}

fx.BASE = [[
{
  "smithy": "2.0",
  "metadata": {},
  "shapes": {
    "ex.api#Svc": {
      "type": "service",
      "version": "1",
      "errors": [{ "target": "ex.api#Throttled" }],
      "traits": {
        "smithy.api#title": "Example API",
        "smithy.api#documentation": "The example API.\n\nSecond paragraph.",
        "com.distilled.telemetry#service": {
          "system": "ex-api",
          "responseHeaders": [{ "header": "x-request-id", "name": "http.response.header.x-request-id", "transform": "list" }],
          "propagation": "w3c"
        }
      }
    },
    "ex.api#GetThing": {
      "type": "operation",
      "input": { "target": "ex.api#GetThingRequest" },
      "output": { "target": "ex.api#ThingResponse" },
      "errors": [{ "target": "ex.api#NotFound" }],
      "traits": {
        "smithy.api#http": { "method": "GET", "uri": "/things/{thing_id}", "code": 200 },
        "smithy.api#documentation": "Get a thing\n\nReturns the thing.",
        "com.distilled.telemetry#operation": { "name": "Ex.GetThing", "method": "Ex/GetThing", "attributes": { "url.template": "/things/{thing_id}" } }
      }
    },
    "ex.api#GetThingRequest": {
      "type": "structure",
      "members": {
        "thing_id": { "target": "smithy.api#String", "traits": { "smithy.api#httpLabel": {}, "smithy.api#required": {}, "com.distilled.telemetry#attributes": [{ "name": "ex.thing_id" }] } },
        "verbose": { "target": "smithy.api#Boolean", "traits": { "smithy.api#httpQuery": "v" } },
        "trace": { "target": "smithy.api#String", "traits": { "smithy.api#httpHeader": "X-Trace" } }
      },
      "traits": { "smithy.api#input": {} }
    },
    "ex.api#ThingResponse": {
      "type": "structure",
      "members": { "thing": { "target": "ex.api#Thing", "traits": { "smithy.api#required": {} } } }
    },
    "ex.api#Thing": {
      "type": "structure",
      "members": {
        "id": { "target": "smithy.api#String", "traits": { "smithy.api#required": {}, "smithy.api#documentation": "The id." } },
        "displayName": { "target": "smithy.api#String", "traits": { "smithy.api#jsonName": "display_name" } },
        "secret": { "target": "smithy.api#String", "traits": { "smithy.api#sensitive": {} } },
        "parent": { "target": "ex.api#Thing" },
        "kind": { "target": "ex.api#Kind", "traits": { "com.distilled.openapi#nullable": {} } },
        "tags": { "target": "ex.api#TagList" },
        "labels": { "target": "ex.api#LabelMap" },
        "size": { "target": "ex.api#Size" },
        "shape": { "target": "ex.api#Shape" },
        "meta": { "target": "ex.api#Meta" },
        "count": { "target": "smithy.api#Long", "traits": { "smithy.api#default": 0 } },
        "created": { "target": "smithy.api#Timestamp" },
        "ratio": { "target": "smithy.api#Double" },
        "big": { "target": "smithy.api#BigInteger" },
        "dec": { "target": "smithy.api#BigDecimal" },
        "small": { "target": "smithy.api#Float" },
        "n": { "target": "smithy.api#Integer" },
        "data": { "target": "smithy.api#Blob" },
        "raw": { "target": "smithy.api#Document" },
        "token": { "target": "ex.api#Token" }
      }
    },
    "ex.api#Token": { "type": "string", "traits": { "smithy.api#sensitive": {} } },
    "ex.api#Kind": {
      "type": "enum",
      "members": {
        "A": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "a" } },
        "B": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "b" } }
      }
    },
    "ex.api#Size": {
      "type": "intEnum",
      "members": {
        "ONE": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": 1 } },
        "TWO": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": 2 } }
      }
    },
    "ex.api#TagList": { "type": "list", "member": { "target": "smithy.api#String" } },
    "ex.api#LabelMap": { "type": "map", "key": { "target": "smithy.api#String" }, "value": { "target": "smithy.api#String" } },
    "ex.api#Shape": {
      "type": "union",
      "members": {
        "Circle": { "target": "ex.api#Circle" },
        "Square": { "target": "ex.api#Square" }
      }
    },
    "ex.api#Circle": {
      "type": "structure",
      "members": {
        "type": { "target": "ex.api#CircleType", "traits": { "smithy.api#required": {} } },
        "r": { "target": "smithy.api#Double" }
      }
    },
    "ex.api#CircleType": { "type": "enum", "members": { "CIRCLE": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "circle" } } } },
    "ex.api#Square": {
      "type": "structure",
      "members": {
        "type": { "target": "ex.api#SquareType", "traits": { "smithy.api#required": {} } },
        "side": { "target": "smithy.api#Double" }
      }
    },
    "ex.api#SquareType": { "type": "enum", "members": { "SQUARE": { "target": "smithy.api#Unit", "traits": { "smithy.api#enumValue": "square" } } } },
    "ex.api#Meta": {
      "type": "structure",
      "members": { "note": { "target": "smithy.api#String" } },
      "traits": { "com.distilled.openapi#additionalProperties": {} }
    },
    "ex.api#ListThings": {
      "type": "operation",
      "input": { "target": "ex.api#ListThingsRequest" },
      "output": { "target": "ex.api#ListThingsResponse" },
      "traits": {
        "smithy.api#http": { "method": "GET", "uri": "/things", "code": 200 },
        "smithy.api#paginated": { "mode": "cursor", "inputToken": "cursor", "outputToken": "pagination.next", "items": "things", "pageSize": "limit" },
        "com.distilled.telemetry#operation": { "name": "Ex.ListThings", "method": "Ex/ListThings", "attributes": { "url.template": "/things" } }
      }
    },
    "ex.api#ListThingsRequest": {
      "type": "structure",
      "members": {
        "cursor": { "target": "smithy.api#String", "traits": { "smithy.api#httpQuery": "cursor" } },
        "limit": { "target": "smithy.api#Integer", "traits": { "smithy.api#httpQuery": "limit" } }
      }
    },
    "ex.api#ListThingsResponse": {
      "type": "structure",
      "members": {
        "things": { "target": "ex.api#ThingList" },
        "pagination": { "target": "ex.api#Pagination" }
      }
    },
    "ex.api#Pagination": { "type": "structure", "members": { "next": { "target": "smithy.api#String" } } },
    "ex.api#ThingList": { "type": "list", "member": { "target": "ex.api#Thing" } },
    "ex.api#PutBlob": {
      "type": "operation",
      "input": { "target": "ex.api#PutBlobRequest" },
      "traits": {
        "smithy.api#http": { "method": "PUT", "uri": "/blobs/{key+}", "code": 204 },
        "com.distilled.telemetry#operation": { "name": "Ex.PutBlob", "method": "Ex/PutBlob", "attributes": { "url.template": "/blobs/{key+}" } }
      }
    },
    "ex.api#PutBlobRequest": {
      "type": "structure",
      "members": {
        "key": { "target": "smithy.api#String", "traits": { "smithy.api#httpLabel": {}, "smithy.api#required": {} } },
        "body": { "target": "smithy.api#Blob", "traits": { "smithy.api#httpPayload": {}, "smithy.api#required": {} } }
      }
    },
    "ex.api#GetBlob": {
      "type": "operation",
      "input": { "target": "ex.api#GetBlobRequest" },
      "output": { "target": "ex.api#GetBlobResponse" },
      "errors": [{ "target": "ex.api#NotFound" }],
      "traits": {
        "smithy.api#http": { "method": "GET", "uri": "/blobs/{key+}", "code": 200 },
        "com.distilled.telemetry#operation": { "name": "Ex.GetBlob", "method": "Ex/GetBlob", "attributes": { "url.template": "/blobs/{key+}" } }
      }
    },
    "ex.api#GetBlobRequest": {
      "type": "structure",
      "members": { "key": { "target": "smithy.api#String", "traits": { "smithy.api#httpLabel": {}, "smithy.api#required": {} } } }
    },
    "ex.api#GetBlobResponse": {
      "type": "structure",
      "members": { "body": { "target": "smithy.api#Blob", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {} } } }
    },
    "ex.api#ListNames": {
      "type": "operation",
      "input": { "target": "ex.api#ListNamesRequest" },
      "output": { "target": "ex.api#ListNamesResponse" },
      "traits": {
        "smithy.api#http": { "method": "GET", "uri": "/names", "code": 200 },
        "com.distilled.telemetry#operation": { "name": "Ex.ListNames", "method": "Ex/ListNames", "attributes": { "url.template": "/names" } }
      }
    },
    "ex.api#ListNamesRequest": { "type": "structure", "members": {} },
    "ex.api#ListNamesResponse": {
      "type": "structure",
      "members": { "body": { "target": "ex.api#TagList", "traits": { "com.distilled.openapi#rawResponse": {}, "smithy.api#required": {} } } }
    },
    "ex.api#NotFound": {
      "type": "structure",
      "members": {},
      "traits": { "smithy.api#error": "client", "smithy.api#httpError": 404, "com.distilled.openapi#errorMatchers": [{ "status": 404 }] }
    },
    "ex.api#Throttled": {
      "type": "structure",
      "members": { "retry_hint": { "target": "smithy.api#Integer" } },
      "traits": {
        "smithy.api#error": "client",
        "smithy.api#httpError": 429,
        "smithy.api#retryable": { "throttling": true },
        "smithy.api#documentation": "Slow down.",
        "com.distilled.openapi#errorMatchers": [{ "status": 429, "message": { "matches": "^slow( down)?$" } }]
      }
    }%EXTRA%
  }
}
]]

--- fx.text(opts) -> model JSON text
-- opts.extra: JSON text of more shapes (`"id": {...}, ...`); opts.replace: list of
-- { old, new } plain substitutions, each of which must match.
function fx.text(opts)
  opts = opts or {}
  local text = fx.BASE
  for _, r in ipairs(opts.replace or {}) do
    local s, e = string.find(text, r[1], 1, true)
    if not s then
      error("gen_fixture: replace target not found: " .. r[1], 2)
    end
    text = string.sub(text, 1, s - 1) .. r[2] .. string.sub(text, e + 1)
  end
  local extra = opts.extra and (",\n" .. opts.extra) or ""
  local s, e = string.find(text, "%EXTRA%", 1, true)
  return string.sub(text, 1, s - 1) .. extra .. string.sub(text, e + 1)
end

function fx.model(opts)
  return require("distilled.gen.model").from_text(fx.text(opts), "ex.json")
end

--- fx.provider(overrides) -> a provider spec table (a fresh copy)
function fx.provider(overrides)
  local p = {
    name = "ex",
    title = "Ex",
    base_url = { default = "https://api.example.test/v1", option = "base_url", env = "EX_BASE_URL" },
    auth = { kind = "bearer", from = "api_key", env = "EX_API_KEY" },
    unknown_tag = "UnknownExError",
    parse_tag = "ExParseError",
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

--- fx.generate(opts) -> files | nil, err, plan  (opts: model opts + provider, ops, telemetry)
function fx.generate(opts)
  opts = opts or {}
  local gen = require("distilled.gen")
  local m, err = fx.model(opts)
  if not m then
    return nil, err
  end
  return gen.generate({
    model = m,
    provider = opts.provider or fx.provider(),
    ops = opts.ops,
    telemetry = opts.telemetry,
  })
end

--- fx.load(source, name) -> the value a generated module returns, with requires redirected
-- `modules` maps module names to values for require inside the chunk.
function fx.load(source, name, modules)
  local compat = require("distilled.compat")
  local chunk, err = compat.load(source, "=" .. (name or "generated"))
  if not chunk then
    error("gen_fixture: generated source does not compile: " .. tostring(err), 2)
  end
  if modules then
    local real = require
    local saved = {}
    for k, v in pairs(modules) do
      saved[k] = package.loaded[k]
      package.loaded[k] = v
    end
    local ok, value = compat.pcall(chunk, name)
    for k in pairs(modules) do
      package.loaded[k] = saved[k]
    end
    local _ = real
    if not ok then
      error(value, 2)
    end
    return value
  end
  return chunk(name)
end

return fx
