# Module contracts

The shapes modules exchange. The plan (`../../distilled-lua-plan.md`) says why; this file
says exactly what. All modules live under `lua/` and are required as `distilled.<name>`.

## Conventions

- Fallible functions return `value` or `nil, err`. `err` is always an error table (below).
- Durations and times are **seconds** as numbers (fractions allowed), except fields whose
  name ends in `_ms`.
- Header names are **lowercase** in every request and response table.

## `distilled.compat`

`compat.unpack`, `compat.load(chunk_string, chunkname)`, `compat.pack(...)` (returns a table
with `n`), `compat.pcall(fn, ...)` (use instead of `pcall`, always), `compat.raise(msg, level)`,
`compat.concat(list [, sep])`, `compat.normalize_number`, `compat.is_integer_subtype`.
Anything else that differs between runtimes goes here.

## `distilled.json`

```lua
json.encode(value [, opts]) -> string | nil, err      -- opts.indent = true
json.decode(text)           -> value  | nil, err
json.null                   -- sentinel for JSON null, in both directions
json.array(t)               -- marks t as an array (so {} encodes as []); returns t
json.object(t)              -- marks t as an object; returns t
json.is_array(t)            -- true for marked tables
```

- Decoded arrays are marked with `json.array`; decoded `null` is `json.null`, including
  inside arrays (`[1,null,3]` has length 3).
- Encoding an unmarked table: keys `1..n` with `n > 0` is an array; anything else, including
  the empty table, is an object. Marks win.
- Numbers that are whole encode without a fraction or exponent up to 2^53. NaN and
  infinities fail with an error. Strings are treated as UTF-8 bytes; control characters and
  `"` `\` are escaped; `\uXXXX` (with surrogate pairs) decodes to UTF-8.
- Object key order when encoding is sorted, so output is deterministic.
- Also: `json.is_object(t)`, `json.MAX_DEPTH` (1000). Decode errors are `ParseError` with
  `err.position`; encode errors are `InvalidInput`. `json.encode` refuses secrets.

## `distilled.errors`

```lua
-- a class
errors.define{ tag = "NotFound", categories = { "NotFoundError" }, retryable = false,
               throttling = false, matchers = { { status = 404 } }, fields = { "code" } }
  -> class
errors.new(class_or_tag, { message = "...", status = 404, ... }) -> err

-- an instance
err.tag          -- string, e.g. "NotFound"
err.message      -- string
err.categories   -- set: { NotFoundError = true }
err.retryable    -- boolean
err.throttling   -- boolean
err.status       -- number or nil (HTTP status)
err.code         -- provider code or nil
err.body         -- parsed body or raw text or nil ("[REDACTED]" when it may hold a secret)
err.headers      -- response headers or nil
err.retry_after  -- seconds or nil
err.trace_id     -- set when tracing is on
err.cause        -- another err or a string, optional
tostring(err)    -- "NotFound: message" (plus " [trace <id>]" when trace_id is set)

errors.is(v)                       -- is v an error table
errors.is_tag(err, "NotFound")
errors.has_category(err, "AuthError")
errors.is_transient(err)           -- Distilled's isTransientError
errors.is_throttling(err)
errors.match(classes, response_info) -> err | nil      -- Distilled's matchTypedError
errors.CATEGORIES                  -- the sixteen names from Distilled's category.ts
```

Built-in classes (same tags, categories and retry marks as `core/src/errors.ts`):
`BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Conflict`, `UnprocessableEntity`,
`Locked`, `TooManyRequests`, `InternalServerError`, `BadGateway`, `ServiceUnavailable`,
`GatewayTimeout`; plus `ConfigError`, `InvalidInput`, `SdkError`, `ParseError`,
`TransportError` (category `NetworkError`), `UnknownError`; and `errors.STATUS_MAP`.

`response_info` for `errors.match`:
`{ status, code, message, body, headers, fields_at, errors = { { code, message }, ... },
retry_after }`. A matched error's `code` is the wire code or `nil`. Instance field names
(`status`, `code`, `message`, `body`, `headers`, `retry_after`, ...) are reserved: a class
field with such a name is not filled from the body. Also exported: `errors.classes[tag]`,
`errors.<Tag>` for built-ins, `errors.is_class`, `errors.at_pointer`,
`errors.RETRYABLE_STATUSES`, `errors.DEFAULT_STATUSES`. Matcher fields and specificity rules
are Distilled's (`trait.ts` `ErrorMatcher`, `protocol-http.ts` `matchTypedError`).
A text matcher is `"exact"` or `{ includes = "...", matches = "<regex source>" }`, exactly
as the model carries it. `matches` is a JavaScript regular expression; `distilled.regex`
(task 03) implements the subset the patches use, and the generator fails when a pattern
does not compile. Until task 03 lands, `errors.match` treats a matcher with `matches` as
not matching.

## `distilled.secret`

```lua
secret.wrap(value) -> s        -- tostring(s) == "<redacted>"; wrapping a secret returns it
secret.unwrap(s_or_value) -> value
secret.is(v) -> boolean
secret.unwrap_deep(value) -> copy with every secret unwrapped (arrays and plain tables)
```

## `distilled.scope`

```lua
Scope.new() -> scope
scope:defer(fn)          -- fn(err_or_nil); returns nothing
scope:close([err]) -> true | nil, errs    -- LIFO, each finalizer under pcall, idempotent
Scope.with(fn) -> ...    -- fn(scope); closes on return and on raise; re-raises the original
```

## Host

One table, passed to a client as `host` (individual fields may also be given at top level).

```lua
host.transport(request) -> response | nil, err
host.sleep(seconds)
host.now() -> seconds          -- wall clock, any epoch, monotonic enough; default os.time
host.exec(argv, opts) -> { code, ok, stdout, stderr, timed_out } | nil, message   -- optional
host.random() -> [0,1)         -- default math.random
host.getenv(name) -> string|nil -- default os.getenv
host.epoch() -> seconds         -- unix time for span timestamps; default os.time
```

```lua
request  = { method = "GET", url = "https://...", headers = { ["authorization"] = "..." },
             body = string | nil, timeout = seconds | nil }
response = { status = 200, headers = { ["content-type"] = "..." }, body = "..." }
```

A transport failure (DNS, connect, timeout, curl missing) is `nil, err` with tag
`TransportError`. A transport must never put header values or the body in process arguments.

## Schema nodes (`distilled.schema`)

Plain tables. Generated code builds them through constructors in `distilled.schema`, but the
tables are the contract.

```lua
{ t = "string" | "number" | "boolean" | "null" | "unknown" | "blob" | "timestamp" }
{ t = "enum",   values = { "a", "b" }, base = "string" | "number" }     -- open: unknown values pass unless strict
{ t = "list",   item = <node> }
{ t = "map",    value = <node> }
{ t = "union",  arms = { <node>, ... }, discriminator = { key = "type", values = { ... } } | nil }
{ t = "ref",    name = "ProjectResponse" }          -- resolved through a registry: { [name] = node }
{ t = "struct", name = "GetProjectRequest", open = false, members = { <member>, ... } }

member = {
  name      = "project_id",      -- the key in the user's Lua table
  wire      = "project_id",      -- wire name; nil means same as name
  bind      = "body",            -- "body" | "label" | "query" | "header" | "payload" | "status"
  schema    = <node>,
  required  = true,
  nullable  = false,
  sensitive = false,
  greedy    = false,             -- label only: {name+}
  style     = nil,               -- query only: "comma" | "deep" | nil
  string_encoded = false,
}
```

`schema.resolve(node, registry)` follows refs. Every algorithm takes the registry as an
argument; nothing global.

## Operation and service descriptors

```lua
service = {
  name      = "neon",
  shapes    = { ProjectResponse = <node>, ... },          -- the registry
  errors    = { NotFound = <error class>, ... },
  ops       = { get_project = <op>, ... },
  telemetry = { system = "neon-api", ... } | nil,
}

op = {
  name    = "GetProject",                 -- upstream name
  method  = "GET",
  uri     = "/projects/{project_id}",
  code    = 200,
  content_type = nil,                     -- nil (json) | "multipart" | "form-urlencoded"
  input   = <struct node>,
  output  = <node> | nil,
  output_raw = false,                     -- true: the whole body is the output value
  errors  = { "BadRequest", "NotFound" }, -- names in service.errors, declaration order
  pagination = { mode = "cursor", input_token = "cursor", output_token = "pagination.cursor",
                 items = "projects", page_size = nil, has_next_page = nil } | nil,
  retry   = { max_attempts = 3, base_ms = 50, ... } | nil,
  span    = "GetProject" | { ... } | nil,
}
```

## Algorithms (layer 2)

```lua
request.build{ op = op, input = t, registry = shapes, base_url = "...", headers = { ... } }
  -> request | nil, err                       -- err: InvalidInput | SdkError
keys.decode(node, value, registry) -> value    -- wire -> user names; marks arrays
keys.encode(node, value, registry) -> value    -- user -> wire names; marks arrays per schema
redact.wrap(node, value, registry) -> value    -- sensitive members become secrets
redact.holds_sensitive(node, registry) -> boolean
validate.check(node, value, registry, { exact = false }) -> true | nil, { path, expected, actual }
```

## Policies (layer 3)

```lua
retry.run(fn, { policy = p, host = h, tracer = t, deadline_s = n }) -> value | nil, err
retry.DEFAULT, retry.THROTTLING, retry.TRANSIENT, retry.NONE
retry.parse_retry_after(headers [, now]) -> seconds | nil
paginate.pages(call, input, trait [, opts]) -> iterator object
paginate.items(call, input, trait [, opts]) -> iterator object
  -- iterator: callable (for x in it do), it.err, it:collect([limit]) -> list | nil, err, it:close()
credentials.resolve(source, host) -> value | nil, err   -- source: string | secret | function
credentials.from_env(name), credentials.from_file(path), credentials.from_command(argv)
```

## Tracer (`distilled.trace`)

```lua
trace.new{ level = "operation" | "debug", exporter = fn | { fn, ... }, host = host,
           service_name = "neon", parent = "<traceparent>" | nil } -> tracer
trace.noop                                  -- same methods, does nothing; tracer.level == "off"

tracer.level
tracer:start(name, { kind = "client" | "internal", attributes = { ... }, debug = false }) -> span
tracer:with(name, opts, fn) -> ...          -- starts, runs fn(span), ends on return/raise/nil,err
tracer:current() -> span | nil
tracer:traceparent() -> string | nil        -- for the outgoing request
tracer:flush() -> true | nil, err

span:set(key, value); span:event(name, attrs); span:fail(err); span:finish()
span.trace_id, span.span_id, span.recording
```

Notes from task 02: exporters are callables invoked as `exporter(spans, meta)` with
`meta = { service_name }`; `memory()` is a callable table with `.spans` and `:clear()`.
`kind` defaults to `"internal"`. Status stays `"unset"` on success. `span:fail(err)` sets
`error.type = err.tag` and the status message. `tracer:with` does not set `err.trace_id`;
the operation layer does. The no-op tracer is `require("distilled.trace.noop")`, a module
that loads nothing else, so a client with tracing off never loads the tracer. Scripts run
by `dl trace` / `dl expect` reach their tracer through `require("verify.lib.trace_env")`.

A span started with `debug = true` is recorded only at level `debug`. Exporters:
`trace.exporters.memory()`, `.file{ path, max_bytes }`, `.console{ write }`,
`.otlp_http{ endpoint, transport }`. Each is `fn(spans) -> true | nil, err`, where a span is

```lua
{ trace_id, span_id, parent_span_id, name, kind, start_ns = "decimal string",
  end_ns = "decimal string", attributes = { ... }, events = { { name, time_ns, attributes } },
  status = { code = "ok" | "error" | "unset", message = nil } }
```

## Protocol, operation, client (layers 4-6)

```lua
rest.new{ base_url = fn(creds) | string, headers = fn(creds) -> table,
          error_envelope = fn(body) -> { code, message } | nil, error_fields_at = "/error" | nil,
          status_map = { ... } | nil, classify_error = fn(info) -> err | nil,
          unknown_tag = "UnknownNeonError", parse_tag = "NeonParseError" } -> protocol
protocol.call(ctx, op, input) -> value | nil, err
  -- ctx = { service, credentials = fn, host, tracer, validation = "lenient"|"additional"|"strict" }

Client.define{ service = service, protocol = protocol, options = { api_key = {...}, ... } } -> Class
Class.new{ ... } -> client
client:<op_name>(input) -> value | nil, err
client:<op_name>_pages(input) / client:<op_name>_items(input) -> iterator      -- paginated ops
client:with{ ... } -> client      -- shallow override; shares budget and credentials cache
client:close()
```

Notes from task 04 (see `STATUS.md` section 04 for the full list):

- `protocol.call` returns `value, nil, meta` or `nil, err, meta` with
  `meta = { status, headers }`; the `link` paginator reads the headers from it.
- A secret option whose environment fallback is unset counts as absent.
- Provider options cannot reuse the names of common client options.
- The tracer has `tracer:attach(span)` / `tracer:detach(span)` for spans that outlive one
  call (a pagination traversal).

## Test harness (`spec/harness.lua`)

```lua
local t = require("spec.harness")
t.describe("json", function()
  t.it("decodes null", function()
    t.eq(json.decode("null"), json.null)
    t.same({ a = 1 }, { a = 1 })          -- deep equality
    t.truthy(x); t.falsy(x); t.err(v, e, "NotFound"); t.match(str, pattern)
  end)
end)
```

`lua spec/run.lua [filter]`, `luajit spec/run.lua [filter]`, and `rex do spec/run.lua`
all run every `spec/*_spec.lua` and exit non-zero (or raise, in Rex) on failure.
