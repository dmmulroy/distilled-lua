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
`compat.concat(list [, sep])`, `compat.normalize_number`, `compat.is_integer_subtype`,
`compat.ERROR_LEVEL_SHIFT`. `compat.pcall` runs `fn` in a coroutine (safe from both
gopher-lua upvalue bugs at any nesting depth, and yield-transparent). Anything else that
differs between runtimes goes here.

## `distilled` (the top-level module)

```lua
local distilled = require("distilled")
distilled.null                   -- json.null
distilled.secret(v)              -- the secret module, callable: wraps v
distilled.errors, distilled.json, distilled.Scope
distilled.scope(fn) -> ...       -- Scope.with
distilled.check(value, err) -> value   -- raises tostring(err) as a string at level 0
distilled.file{ data, filename?, content_type? } -> file    -- distilled.multipart.file
-- loaded on first use: distilled.Client, .rest, .retry, .paginate, .credentials, .host
```

`distilled.check` raises at **level 0**: the message is exactly `tostring(err)` (no
`file:line:` prefix), because Rex shows the raised string as an action's failure. With
no value and no error it raises `distilled.check: no value and no error`.

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
does not compile. Also exported: `errors.matches_expression`, `errors.matcher_specificity`.
`errors.new` with an unknown tag string makes a category-less class; `InvalidInput`
declares `member`, `ConfigError` declares `key`.

## `distilled.secret`

```lua
secret.wrap(value) -> s        -- tostring(s) == "<redacted>"; wrapping a secret returns it
secret.unwrap(s_or_value) -> value
secret.is(v) -> boolean
secret.unwrap_deep(value) -> copy with every secret unwrapped (arrays and plain tables)
secret.REDACTED
```

`unwrap_deep` keeps metatables (json array marks, multipart files), copies a table
reached twice once, and returns `json.null` as itself.

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
host.random() -> [0,1)         -- default: a private Park-Miller generator seeded from the
                               -- clock and an address (math.random's state is not touched)
host.getenv(name) -> string|nil -- default os.getenv
host.epoch() -> seconds         -- unix time for span timestamps; default os.time
```

The default `sleep` is a busy wait on `os.clock` (pure Lua cannot sleep); there is no
default transport (a call fails with `ConfigError`, `err.key = "transport"`).
`require("distilled.host")` has `merge(base, top)`, `default()`, `check(value, name,
level)`, `callable(v)`, `FIELDS`, `TRANSPORT_HINT`.

Hosts and transports shipped with the runtime:

```lua
require("distilled.host.popen")([opts]) -> host    -- stock Lua / LuaJIT: popen_curl
  -- transport = popen_curl(opts), sleep = popen_curl.sleep, now = os.time, epoch = os.time,
  -- name = "popen"; no exec. Raises inside Rex (no io.popen).
require("distilled.host.rex")([opts]) -> host      -- Rex only (the only module naming rex)
  -- transport = exec_curl(rex.exec, opts), exec, sleep, now = os.clock, epoch = os.time,
  -- getenv, name = "rex"; random left to the default
require("distilled.transport.popen_curl")([opts]) -> transport   -- also .new(opts)
  -- opts = { curl = "curl", follow_redirects = false, tmpdir = nil }
require("distilled.transport.popen_curl").sleep(seconds)          -- a child `sleep` process
require("distilled.transport.exec_curl")(exec [, opts]) -> transport   -- also .new
  -- exec has rex.exec's contract
```

The two transport modules are constructors, not transports: each carries
`transport_module = "<module name>"`, and `host.check` (so `Class.new`) raises when one
is passed as a transport, naming what to pass instead. A transport whose result is a
function, nothing (`nil, nil`) or a non-table is a `ConfigError` (`key = "transport"`,
not retried) at call time. Transport errors: `TransportError` with `err.curl_code`,
`err.timeout = true` (+ category `TimeoutError`) and `err.tls = true` where they apply; a
request that breaks the contract (CR/LF in a header, a bad URL or method) is
`InvalidInput` from the transport.

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
argument; nothing global. Any node may also carry `sensitive = true` (Smithy puts
`@sensitive` on shapes; list items and map values have no member);
`schema.node_sensitive(node, registry)` reads it through refs.

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
  body_media_type = nil,                  -- set: a string payload is sent raw
  server  = nil,                          -- passed to a base_url function's route
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

- `pagination.mode` is one of `token`, `cursor`, `page`, `relay`, `link`, `keyset`,
  `single`; trait paths are user names (after key mapping).
- `op.retry` keys are snake_case of `distilled.retry#policy` (`max_attempts`, `base_ms`,
  `throttling_base_ms`, `cap_ms`, `factor`, `long_poll`).
- `op.span` and `service.telemetry` are Distilled's compressed telemetry form with
  snake_case keys (`STATUS.md`, section 06): `op.span` is the model op name when
  everything derives, else `{ op, name, method, kind, template, attributes, input,
  output }`; the span name is `<service.telemetry.prefix>.<op>`.
- `output_raw` is written by the generator (the output is that member's value); the REST
  protocol does not read it: a `blob` output node returns the body bytes untouched.

## Algorithms (layer 2)

```lua
request.build{ op = op, input = t, registry = shapes, base_url = "...", headers = { ... },
               map_member_header = fn(name, value) -> value,   -- optional
               unknown_key_to_wire = fn(key) -> wire,          -- optional
               empty_json_body = false, query_style = "dotted" | "brackets",
               random = fn() -> [0, 1), host = { random } }     -- multipart boundary
  -> request | nil, err                       -- err: InvalidInput | SdkError
keys.decode(node, value, registry) -> value    -- wire -> user names; marks arrays
keys.encode(node, value, registry) -> value    -- user -> wire names; marks arrays per schema
redact.wrap(node, value, registry) -> value    -- sensitive members become secrets
redact.holds_sensitive(node, registry) -> boolean
redact.plain(node, text, registry) -> text     -- for logs and error bodies
redact.parsed(node, value, registry) -> value
validate.check(node, value, registry, { exact = false })
  -> true | nil, { path, expected, actual, missing, message }   -- list indices 1-based
validate.withhold(mismatch) -> mismatch        -- for parse errors that must not show the body
```

- A missing label and a header value with CR/LF are `InvalidInput`.
- A `payload` is JSON, or the string itself when its schema is `blob` or the operation
  has `body_media_type`.
- **Multipart** (`op.content_type = "multipart"`): the body is `multipart/form-data` (RFC
  7578, the bytes undici writes), whatever the method. Body members are parts under their
  wire names in declaration order (undeclared keys after, sorted). A file value
  (`distilled.file{...}`) is a file part with its filename (else the wire name) and
  content type (else `application/octet-stream`); a string at a `blob` node is a file
  part named after the member; a non-empty list of binaries is one part per element;
  other tables are JSON parts, scalars their string; `json.null` and absent values are
  omitted; a payload record is one part per entry, sorted. The boundary is
  `----distilled-lua-` and 24 alphanumerics from `random` (or `host.random`; through a
  client, the client's host), drawn again while it occurs in a part; without either it
  comes from `distilled.host`'s default generator.

```lua
local multipart = require("distilled.multipart")
multipart.file{ data, filename?, content_type? } -> file   -- = distilled.file; data may be a secret
multipart.is_file(v) -> boolean
multipart.encode(parts, { random }) -> { body, content_type, boundary } | nil, err
multipart.boundary(random), multipart.escape_name(s), multipart.escape_filename(s)
```

## Policies (layer 3)

```lua
retry.run(fn, { policy = p, host = h, tracer = t, span = s, deadline_s = n,
                server_hint_cap_s = n }) -> value, nil, meta | nil, err, meta
retry.DEFAULT, retry.THROTTLING, retry.TRANSIENT, retry.NONE
retry.parse_retry_after(headers [, now]) -> seconds | nil
retry.new_budget(opts) -> budget            -- per-host retry budget (`budget` client option);
                                            -- default retry.default_budget, process-wide
paginate.pages(call, input, trait [, opts]) -> iterator object
paginate.items(call, input, trait [, opts]) -> iterator object
  -- iterator: callable (for x in it do), it.err, it:collect([limit]) -> list | nil, err, it:close()
credentials.resolve(source, host [, name]) -> secret | nil, err  -- source: string | secret | fn(host)
credentials.from_env(name), credentials.from_file(path), credentials.from_command(argv [, opts])
  -- from_command needs host.exec
```

## Tracer (`distilled.trace`)

```lua
trace.new{ level = "operation" | "debug", exporter = fn | { fn, ... }, host = host,
           service_name = "neon", parent = "<traceparent>" | nil } -> tracer
trace.noop                                  -- same methods, does nothing; tracer.level == "off"

tracer.level
tracer:start(name, { kind = "client" | "internal" | "server", attributes = { ... }, debug = false }) -> span
tracer:with(name, opts, fn) -> ...          -- starts, runs fn(span), ends on return/raise/nil,err
tracer:current() -> span | nil
tracer:traceparent() -> string | nil        -- for the outgoing request
tracer:flush() -> true | nil, err
tracer:detach(span) -> boolean               -- keep an open span off the active stack
tracer:attach(span) -> boolean               -- make a detached open span current again

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
Span assertions for tests are `require("distilled.testing.expect")` (formerly
`distilled.trace.expect`; under `testing/`, so `distilled-lua vendor` does not ship it).
Also exported: `trace.NOOP_SPAN`, `trace.parse_traceparent`, `trace.ns_diff_ms`,
`trace.attribute_value`, `trace.tag_of`.

A span started with `debug = true` is recorded only at level `debug`. Exporters:
`trace.exporters.memory()`, `.file{ path, max_bytes }`, `.console{ write }`,
`.otlp_http{ endpoint, transport, headers, timeout, service_name }`. Each is
`fn(spans, meta) -> true | nil, err`, where a span is

```lua
{ trace_id, span_id, parent_span_id, name, kind, start_ns = "decimal string",
  end_ns = "decimal string", attributes = { ... }, events = { { name, time_ns, attributes } },
  status = { code = "ok" | "error" | "unset", message = nil } }
```

## Protocol, operation, client (layers 4-6)

```lua
rest.new{ base_url = fn(creds, { uri, method, server }) | string, headers = fn(creds) -> table,
          error_envelope = fn(body) -> { code, message } | nil, error_fields_at = "/error" | nil,
          status_map = { [status] = class } | nil, classify_error = fn(info) -> err | nil,
          unknown_tag = "UnknownNeonError", parse_tag = "NeonParseError",
          unknown_error = fn(info) -> err, parse_error = fn(info) -> err,
          transform_response = fn(body) -> body, user_agent = "...",
          map_member_header, unknown_key_to_wire, empty_json_body, query_style } -> protocol
rest.bearer(option_name), rest.header(header_name, option_name)   -- headers functions
protocol.call(ctx, op, input) -> value, nil, meta | nil, err, meta
protocol.encode(ctx, op, input [, creds]) -> request | nil, err   -- no send
protocol.decode(ctx, op, response) -> value | nil, err
  -- ctx = { service, op_name, credentials = fn() -> creds | nil, err, host, tracer, span,
  --         validation = "lenient"|"additional"|"strict", timeout, attempt, user_agent }

Client.define{ service = service, protocol = protocol, options = { api_key = {...}, ... } } -> Class
Class.new{ ... } -> client
client:<op_name>(input) -> value | nil, err
client:<op_name>_pages(input) / client:<op_name>_items(input) -> iterator      -- paginated ops
client:with{ ... } -> client      -- shallow override; shares budget and credentials cache
client:close()
```

`Class.new{}` / `client:with{}` take the provider's options plus the common ones: `host`,
the host fields at top level (`transport`, `sleep`, `now`, `exec`, `random`, `getenv`,
`epoch`; top level wins over `host`), `retry`, `deadline_s`, `tracing`, `tracer`,
`trace_parent`, `validation`, `budget`, `server_hint_cap_s`, `user_agent`. Unknown names
and wrongly typed values raise (misuse, level 2); the full rules are in `STATUS.md`,
section 04.

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
all run every `spec/*_spec.lua` and exit non-zero (or raise, in Rex) on failure; use
`verify/dl test [filter]`, which runs all three. Also: `t.ne`, `t.no_match`,
`t.raises(fn, pattern)`, `t.fails_with(tag, f(...))`, `t.fail`, `t.pending`, `t.show`,
`t.pcall`, `t.root`.

## Test seams (`distilled.testing`, never required by library code)

```lua
testing.transport{ responses = { ... } }  -- callable table; tr.requests; raises when it runs out
testing.host{ now = 0, epoch = 1700000000, seed = 1, env = { ... }, responses = { ... },
              transport = tr, exec = fn }
  -- + sleeps, clock, advance(s), requests; random is testing.random(seed)
testing.random(seed) -> fn               -- Park-Miller, identical on every runtime
require("distilled.testing.fixtures")    -- the task 03 fixture service
require("distilled.testing.expect")      -- span assertions (verify/features/tracing.md)
```

## `distilled.crypto` (task 14)

Pure Lua 5.1, no `bit`/`bit32`, identical results on lua 5.5, LuaJIT and gopher-lua.
Every function takes and returns byte strings (a Lua string is UTF-8 bytes already).
Wrong argument types raise (level 2); malformed encoded input returns `nil, err`.

```lua
local crypto = require("distilled.crypto")
crypto.digest(name, message) -> binary digest
  -- name: "md5" | "sha1" | "sha224" | "sha256" | "sha384" | "sha512" | "sha3_256" | "keccak256"
crypto.sha256(message), crypto.sha1(message), ... (one per name)  -> binary digest
crypto.hmac(name, key, message) -> binary MAC        -- key: string or distilled.secret
crypto.hmac_sha256(key, message), crypto.hmac_sha1, crypto.hmac_sha512, ... (one per name)
crypto.hash_function(name) -> fn(message), block_size   -- raises on an unknown name
crypto.HASHES[name] = { module, block size, digest length }
crypto.crc32(message [, crc]) -> number, crypto.crc32c(message [, crc]) -> number
crypto.equal(a, b) -> boolean            -- compares every byte (signature checks)
crypto.hex.encode(s) -> lowercase hex;   crypto.hex.decode(h) -> bytes | nil, InvalidInput
crypto.base64.encode(s) -> padded;       crypto.base64.decode(text) -> bytes | nil, InvalidInput
crypto.base64.url_encode(s [, pad]) -> unpadded unless pad; crypto.base64.url_decode(text)
```

- Modules: `distilled.crypto.{sha2, sha1, md5, keccak, hmac, crc32, hex, base64}`, plus
  the internals `bytes` (lookup tables) and `codegen` (source generation). `sha2.digest(name,
  message)`, `sha1.digest`, `md5.digest`, `keccak.keccak256` / `keccak.sha3_256`,
  `crc32.crc32` / `crc32.crc32c` / `crc32.bytes(n)` (4-byte big-endian, what S3 base64s).
- base64 decoding is strict about the alphabet (no whitespace, no mixing `+/` with `-_`),
  accepts input with or without padding, and rejects misplaced padding and lengths 4n+1.
- The compression functions are generated Lua source compiled on first use
  (`sha2.source(name)`, `sha1.source()`, `md5.source()`, `keccak.source()` return it).
  First use costs 20 ms (lua) to 110 ms (Rex) for all of them.

## `distilled.sigv4` (task 14)

AWS Signature Version 4, a port of `@distilled.cloud/aws4signer` (aws4fetch's rules,
byte for byte).

```lua
local sigv4 = require("distilled.sigv4")
sigv4.sign{
  request = { method?, url, headers?, body?, ... },   -- the distilled request table
  credentials = { access_key_id, secret_access_key, session_token? },  -- secrets allowed
  region?, service?,          -- guessed from the host when absent (region: us-east-1)
  now_epoch = seconds | datetime = "YYYYMMDDTHHMMSSZ",   -- one is required
  sign_query?,                -- presign: signature in the query instead of headers
  all_headers?,               -- also sign content-type, range, user-agent, ...
  hash_payload?,              -- send and sign x-amz-content-sha256 (S3: instead of UNSIGNED-PAYLOAD)
  append_session_token?,      -- add the token after signing (always for iotdevicegateway)
  single_encode?,             -- encode the path once (default: twice outside S3)
  key_cache?,                 -- a table the caller owns (one per client): derived keys,
                              -- by sha256(secret) and scope, at most 16
} -> signed | nil, err
sigv4.presign{ url, method?, headers?, credentials, region?, service?, expires_in?,
               now_epoch | datetime, all_headers?, append_session_token?, single_encode? }
  -> url | nil, err
sigv4.canonical_request{ same as sign } -> string | nil, err   -- holds the session token: do not log
sigv4.signing_key(secret_access_key, "YYYYMMDD", region, service) -> binary key
sigv4.guess_service_region(url [, headers]) -> service, region   ("" when unknown)
sigv4.amz_datetime(epoch) -> "YYYYMMDDTHHMMSSZ"
sigv4.UNSIGNABLE_HEADERS
```

- `signed` is a shallow copy of `request` (other fields such as `timeout` kept) with
  `method` (defaults: POST with a non-empty body, else GET), `url` (normalised as `new
  URL()` does; with `sign_query` the X-Amz-* parameters are added and the whole query is
  re-serialised form-style, like `URLSearchParams.set`) and `headers` replaced: lower-case
  names, values trimmed, `host` removed (the transport sends it), and `x-amz-date`,
  `x-amz-security-token`, `x-amz-content-sha256` (S3: `UNSIGNED-PAYLOAD` by default) and
  `authorization` added. The input request is not modified.
- Errors: a URL that is not absolute http(s) or a header with a non-token name, a
  non-string value or NUL/CR/LF is `InvalidInput` (messages never carry a header value
  or the URL); missing `access_key_id` / `secret_access_key` (or a non-string
  `session_token`) is `ConfigError` with `err.key`. Unknown or mistyped arguments, no
  time, a malformed `datetime` or a non-string body raise (misuse).
- Not ported: SigV4A (`signV4a`, needs ECDSA P-256) and `AwsClient` (the protocol layer
  will call `sign`). The derived-key cache is the caller's `key_cache` table instead of a
  module-level map (without one, each call derives the key: 4 HMACs). Differences from Distilled: `hash_payload` replaces an existing
  `x-amz-content-sha256` header (Distilled joins two differently-cased ones); header
  names that differ only in case are joined in sorted order (a Lua table has no
  insertion order); header values are bytes, so only ASCII whitespace is collapsed.
