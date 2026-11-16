# Using a generated client

Everything here applies to any generated client; the examples use Neon
(`clients/neon`). Runnable versions: `examples/plain_lua.lua` (stock Lua over HTTP),
`examples/custom_transport.lua` (a transport and host of your own, no network), both run
as described at the top of each file.

## Getting the modules onto `package.path`

A client needs two directories: the runtime (`lua/distilled/`, or a vendored copy, see
`docs/generating.md`) and the generated module (`clients/neon/`, required as `neon`).

```lua
package.path = "/path/to/vendor/?.lua;/path/to/vendor/?/init.lua;" .. package.path
local distilled = require("distilled")
local Neon = require("neon")
```

## Constructing a client

```lua
local neon = Neon.new({
  api_key = os.getenv("NEON_API_KEY"),        -- provider option (secret); default: NEON_API_KEY
  base_url = "https://console.neon.tech/api/v2", -- provider option; default: NEON_API_BASE_URL or this
  host = require("distilled.host.popen")(),   -- how to do HTTP, sleep and tell time
  retry = { max_retries = 5 },                -- optional, see "Retry and deadlines"
  deadline_s = 20,                            -- optional
  validation = "lenient",                     -- optional: "lenient" | "additional" | "strict"
  tracing = "off",                            -- optional: see docs/tracing.md
})
```

- **Provider options** come from the provider spec: Neon has `api_key` (a secret,
  falling back to `NEON_API_KEY`) and `base_url` (falling back to `NEON_API_BASE_URL`,
  then the default URL). A required option that is missing does not raise in `new`: the
  first call fails with `ConfigError` (`err.key = "api_key"`).
- **Common options** (every client): `host`, or its fields at top level (`transport`,
  `sleep`, `now`, `epoch`, `random`, `getenv`, `exec`; top level wins), `retry`,
  `deadline_s`, `budget`, `server_hint_cap_s`, `validation`, `tracing`, `tracer`,
  `trace_parent`, `user_agent`. An unknown option name raises at once and lists the valid
  ones (misuse is the only thing that raises).
- **`client:with{...}`** returns a client with some options replaced. It shares the
  credential cache, the retry budget and the tracer with its parent:

```lua
local patient = neon:with({ retry = "transient", deadline_s = 25 })
local quick = neon:with({ retry = "none" })
```

- `client:close()` exports any buffered spans and closes the client's scope; calls still
  work afterwards.

## Calling

Each operation is a method named in `snake_case` after the model's operation
(`GetProject` -> `get_project`). The input is one table whose keys are the wire names
(Neon's API uses `snake_case` already); path, query and body placement come from the
model. `clients/neon/README.md` lists every operation and `clients/neon/types.lua` has
LuaLS type annotations for inputs and outputs.

```lua
local res, err = neon:get_project({ project_id = "quiet-sun" })
local key, err2 = neon:create_api_key({ key_name = "ci" })
local branch, err3 = neon:update_project_branch({
  project_id = "p1", branch_id = "b1", branch = { name = "main" },
})
```

- JSON `null` is `distilled.null`; send it to clear a nullable field
  (`{ settings = distilled.null }`). An absent key is not sent.
- An empty table is sent as `{}`, or as `[]` where the schema says list; mark it
  yourself with `distilled.json.array({})` when the schema says `unknown`.
- Keys the model does not declare are sent in the body as given (as Distilled does).
- Responses are plain tables; JSON arrays are marked (`distilled.json.is_array`), nulls are
  `distilled.null`. Operations whose response is raw (Neon's bucket object download)
  return the body string.

### Raising instead: `distilled.check`

```lua
local res = distilled.check(neon:get_project({ project_id = "p1" }))
```

`check(value, err)` returns `value`, or raises `tostring(err)` as a plain string with no
`file:line:` prefix (useful where a string error is wanted, like a Rex action).
`assert(neon:get_project(...))` does not work on gopher-lua (its `assert` rejects table
messages); use `check`.

## Errors and categories

A failed call returns `nil, err`. `err` is a table:

| Field | |
| --- | --- |
| `tag` | the error's name: a model error (`"NotFound"`), a built-in (`"TooManyRequests"`), or `ConfigError`, `InvalidInput`, `TransportError`, `SdkError`, `UnknownNeonError`, `NeonParseError` |
| `categories` | a set: `err.categories.AuthError`, `.NotFoundError`, `.ThrottlingError`, `.ServerError`, `.NetworkError`, `.ParseError`, ... (Distilled's sixteen) |
| `retryable`, `throttling` | the retry marks |
| `status` | HTTP status, on every HTTP error |
| `code`, `message` | from the error body (`code` is the wire code or nil) |
| `body`, `headers` | the parsed error body (or its text) and the response headers |
| `retry_after` | seconds, from `Retry-After`, on retryable errors |
| `trace_id` | when tracing is on |

`tostring(err)` is `"NotFound: project not found"` (plus ` [trace <id>]` with tracing).

How a failed response becomes an error, in order: the operation's declared errors from
the model (most specific matcher wins: status, code, message, headers, body fields);
then the status map (400 `BadRequest`, 401 `Unauthorized`, 403 `Forbidden`, 404
`NotFound`, 409 `Conflict`, 422 `UnprocessableEntity`, 423 `Locked`, 429
`TooManyRequests`, 500/502/503/504); otherwise `UnknownNeonError` (with `status`). A 2xx
body that cannot be decoded where it must be (strict validation, or a non-JSON body for
an output holding secrets) is `NeonParseError`. Before sending: a missing or `.`/`..` path
label, or a header value with a newline, is `InvalidInput`; a missing key is
`ConfigError`.

```lua
local errors = distilled.errors
if errors.is_tag(err, "NotFound") then ... end
if errors.has_category(err, "AuthError") then ... end
if errors.is_transient(err) then ... end   -- what the default retry policy retries
```

### Differences from Distilled (TypeScript)

Measured by `verify/dl conform neon`, all deliberate:

- `err.status` is set on every HTTP error (Distilled's typed classes have none).
- `err.code` is the wire code or `nil` (Distilled has `0` on generated classes).
- A missing path label fails with `InvalidInput` (Distilled sends `{project_id}`).
- Parse errors have a message saying what failed (Distilled's is empty).
- Transport failures are `TransportError` with category `NetworkError`.
- An asctime `Retry-After` date is read as GMT.

## Pagination

Paginated operations get two extra methods (Neon: 11 operations, all cursor-based):

```lua
-- every item across pages
local it = neon:list_projects_items({ limit = 50 })
for project in it do print(project.id) end
if it.err then return nil, it.err end          -- a for loop cannot carry an error

-- or collect, up to a limit
local projects, err = neon:list_projects_items({}):collect(200)

-- one page (the whole response) at a time
for page in neon:list_projects_pages({ limit = 10 }) do print(#page.projects) end
```

The iterator stops at the first failure and records it in `it.err` (items already
produced stay produced), stops when the cursor is absent, `null` or `""`, and stops when
a cursor repeats. `it:close()` ends a traversal early (its span, when tracing). Each page
is a normal call with its own retries. The plain method (`neon:list_projects{}`) still
returns one page.

## Retry and deadlines

The default policy is Distilled's: retry only errors that are transient (marked
retryable: 408, 423, 429, 500, 502, 503, 504, and transport errors), at most 2 retries,
full-jitter backoff from 50 ms (1 s for throttling) capped at 20 s, a `Retry-After` as a
minimum wait, and a shared per-host retry budget so an outage does not multiply traffic.
A `Retry-After` over 60 s (`server_hint_cap_s`) stops retrying and returns the error.

```lua
Neon.new({ retry = "none" })                 -- presets: "default", "throttling", "transient", "none"
Neon.new({ retry = { max_retries = 5, cap_ms = 5000 } })   -- fields over the default
Neon.new({ deadline_s = 20 })                -- whole call, sleeps included
Neon.new({ retry = { deadline_s = 20 } })    -- the same
Neon.new({ budget = require("distilled.retry").new_budget({ initial = 50 }) })
```

`"throttling"` retries only throttling errors and `"transient"` all transient ones, both
without a retry limit or budget (1 s base, 5 s cap): pair them with `deadline_s`. With a
deadline, a backoff that would pass it returns the last error instead, and each attempt
gets the time left as its transport timeout. Retries need a real `sleep` on the host
(see below).

## Secrets and credentials

- Response fields the model marks sensitive (Neon's new API key) are wrapped:
  `tostring(v)` is `<redacted>`, `distilled.secret.unwrap(v)` gives the value.
  `distilled.json.encode` refuses a wrapped secret, so it cannot slip into a log by
  accident. Error bodies that might hold one show `"[REDACTED]"`.
- Inputs may be plain strings or `distilled.secret("...")`.
- A secret option (`api_key`) is a string, a secret, or a function returning the value
  (or `nil, err`). A function is called when a request first needs it, cached, and called
  again once when a call fails with 401 (then retried once): that is token refresh.

```lua
local credentials = require("distilled.credentials")
Neon.new({ api_key = credentials.from_file(os.getenv("HOME") .. "/.config/neon/key") })
Neon.new({ api_key = credentials.from_command({ "op", "read", "op://dev/neon/key" }), exec = my_exec })
Neon.new({ api_key = credentials.from_env("MY_NEON_KEY") })
```

`from_command` runs through the host's `exec` (`distilled.host.rex` has one; stock Lua
hosts do not). No error message ever quotes a credential, a key file's contents or a
command's output; transports keep keys out of process arguments.

## Validation modes

What happens when a 2xx body does not match the model:

| `validation` | |
| --- | --- |
| `"lenient"` (default) | returned as received; missing members and wrong types pass |
| `"additional"` | checked against the schema; a mismatch is `NeonParseError`; extra keys allowed |
| `"strict"` | as `additional`, and a key the model does not declare is a mismatch too |

The error's message names the path (`... Expected object, got "x" at ["project"]`). In
every mode a non-JSON body for an output holding secrets fails, with the body withheld.

## Scope

`distilled.scope(fn)` runs `fn(scope)` and then runs everything deferred on the scope
(last in, first out), also when `fn` raises:

```lua
distilled.scope(function(scope)
  local f = assert(io.open(path, "w"))
  scope:defer(function() f:close() end)
  ...
end)
```

The library uses the same primitive internally to end spans, flush trace exporters and
remove temporary files on every exit path.

## The host seam

All I/O goes through a `host` table, so the same client runs anywhere:

| Field | Contract | Default |
| --- | --- | --- |
| `transport(req)` | `req = { method, url, headers, body, timeout }` -> `{ status, headers, body }` or `nil, err` | none: a call fails with `ConfigError` (`err.key = "transport"`) |
| `sleep(seconds)` | wait | a busy loop (pure Lua cannot sleep): pass a real one |
| `now()` | seconds, monotonic enough | `os.time` |
| `epoch()` | Unix seconds, for span timestamps | `os.time` |
| `random()` | `[0, 1)` | a private generator seeded per process |
| `getenv(name)` | environment | `os.getenv` |
| `exec(argv, opts)` | `{ code, ok, stdout, stderr, timed_out }` | none |

Header names are lowercase in both directions. Ready-made hosts:

- `require("distilled.host.popen")([opts])`: stock Lua and LuaJIT. curl through `io.popen`
  (`distilled.transport.popen_curl`, request and key in 0600 temp files, never in argv),
  `sleep` in a child process, `now = os.time` (so deadlines and span durations are whole
  seconds). `opts` go to popen_curl: `curl` (path), `follow_redirects`, `tmpdir`.
- `require("distilled.host.rex")()`: inside Rex, see `docs/rex.md`.
- `require("distilled.transport.exec_curl")(exec [, opts])`: a curl transport over any
  `exec` function with `rex.exec`'s contract (config and body on stdin, nothing on disk).

### Writing a transport

A transport is a function. It must return the whole body as a string, lowercase the
response header names (join repeated headers with `, `), not follow redirects unless
asked, honour `req.timeout` (seconds), and return `nil, err` for anything that is not an
HTTP response, normally `distilled.errors.new("TransportError", { message = ... })`.
It must never put header values or the body into process arguments or error messages.
`examples/custom_transport.lua` is a complete one (canned answers, a recording host,
retry on a 503, a credential function). Transport failures are retried as transient
errors.

```lua
local function transport(req)
  local status, headers, body = my_http(req.method, req.url, req.headers, req.body, req.timeout)
  if not status then
    return nil, distilled.errors.new("TransportError", { message = "connect failed" })
  end
  return { status = status, headers = headers, body = body or "" }
end
local neon = Neon.new({ transport = transport, sleep = my_sleep, now = my_clock })
```
