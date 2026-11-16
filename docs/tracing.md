# Tracing

distilled-lua records OpenTelemetry spans for its calls, with names and attributes taken
from the telemetry traits in Distilled's models, so a Lua call and a TypeScript call to
the same operation produce the same span. It is off by default; when off, the tracing
module is not even loaded.

## Levels

```lua
Neon.new({ tracing = "off" })        -- default
Neon.new({ tracing = "operation" })  -- one CLIENT span per call (around all its retries),
                                     -- one span per pagination traversal
Neon.new({ tracing = "debug" })      -- plus attempts, backoff, credentials, request build,
                                     -- transport and decode
local quiet = neon:with({ tracing = "off" })
```

A string level writes the span tree to `io.stderr` (the console exporter). The long form
picks the exporter:

```lua
tracing = { level = "operation", file = "/tmp/neon.jsonl", max_bytes = 1000000 }
tracing = { level = "debug", exporter = my_exporter }   -- fn(spans, meta) -> true | nil, err
tracer = existing_tracer                                 -- share one tracer (tests, dl trace)
trace_parent = "00-<trace>-<span>-01"                    -- continue a caller's trace
```

Spans are exported when the outermost call (or traversal) returns, so nothing is left
buffered at the end of a Rex action. A failing exporter never fails the call.

When tracing is on, a failed call's error has `err.trace_id`, and `tostring(err)` ends
with ` [trace <id>]`.

## Exporters

`require("distilled.trace").exporters`:

| Exporter | |
| --- | --- |
| `memory()` | keeps spans in `.spans` (tests; `:clear()`) |
| `file{ path, max_bytes }` | one OTLP/JSON `{"resourceSpans":[...]}` line per flush, appended; the file is truncated first once it is larger than `max_bytes`; only `io.open`, so it works in Rex |
| `console{ write }` | the indented span tree (`write` defaults to stderr) |
| `otlp_http{ endpoint, transport, headers, timeout }` | POST OTLP/JSON to a collector (`<endpoint>/v1/traces`), itself untraced; failures come back from the flush as `SdkError` |

## What is recorded

From `verify/dl trace examples/fake_service.lua --level debug` (a call retried after 429
and 503, a two-page listing, a 404; lines shortened):

```text
trace 0320c25eb468037985540da37c2df4be
  Neon.GetProject client 1045.3ms unset distilled.attempts=3 distilled.retry.delay_ms=1045
      distilled.retry.errors=[TooManyRequests,ServiceUnavailable] http.request.method=GET ...
    distilled.attempt 0.1ms ERROR "slow down" distilled.attempt=1 error.type=TooManyRequests
        http.request.resend_count=0 http.response.status_code=429
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=429 server.address=console.neon.tech
      distilled.decode 0.0ms ERROR "slow down" error.type=TooManyRequests
    distilled.retry.backoff 1000.0ms unset distilled.retry.attempt=1 distilled.retry.delay_ms=1000 distilled.retry.reason=TooManyRequests
    distilled.attempt 0.1ms ERROR "try again" distilled.attempt=2 error.type=ServiceUnavailable ...
    ...
trace 73ec1e72b5c4b6be113768ce6df201de
  distilled.pagination 0.6ms unset distilled.pagination.items=3 distilled.pagination.kind=items
      distilled.pagination.mode=cursor distilled.pagination.operation=Neon.ListProjects
      distilled.pagination.pages=2 distilled.pagination.stop=no_token
    Neon.ListProjects client 0.1ms unset http.request.method=GET http.response.status_code=200
        rpc.method=Neon/ListProjects rpc.system.name=neon-api server.address=console.neon.tech
        server.port=443 url.template=/projects
    ...
trace a4245a7f8aed1a682b9cff2f43e227d1
  Neon.GetProject client 0.1ms ERROR "project not found" error.type=NotFound http.request.method=GET
      http.response.status_code=404 neon.project_id=proj-missing rpc.method=Neon/GetProject ...
      url.template="/projects/{project_id}"
```

### Span names and attributes

| Span | Level | Attributes |
| --- | --- | --- |
| `<Service>.<Operation>` (`Neon.GetProject`), kind CLIENT | operation | `rpc.system.name`, `rpc.method` (`Neon/GetProject`), `url.template`, `http.request.method`, `server.address`, `server.port`, `http.response.status_code`, `error.type` (the error tag) on failure, input members the model's telemetry trait names (`neon.project_id`), response headers it names (`http.response.header.x-request-id`); after retries `distilled.attempts`, `distilled.retry.errors`, `distilled.retry.delay_ms`, `distilled.retry.stopped` (`budget`, `deadline`, `hint_over_cap`) |
| `distilled.pagination` | operation | `distilled.pagination.operation`, `.mode`, `.kind` (`items`/`pages`), `.pages`, `.items`, `.stop` (why it ended) |
| `distilled.attempt` | debug | `distilled.attempt` (1-based), `http.request.resend_count`, `http.response.status_code`, `error.type` |
| `distilled.credentials`, `distilled.request.build`, `distilled.decode` | debug | `error.type` on failure |
| `distilled.transport` | debug | `http.request.method`, `server.address`, `http.response.status_code` |
| `distilled.retry.backoff` | debug | `distilled.retry.attempt`, `distilled.retry.delay_ms`, `distilled.retry.reason` |

Status is `unset` on success and `ERROR` with the error's message on failure.

### Secrets and propagation

- Inputs are recorded only where the telemetry trait names a member; header values are
  never recorded; a secret value becomes `<redacted>` anywhere in a span.
  `verify/dl canary` runs a client with a known fake key at debug level and fails if the
  key shows up in a trace, stdout, stderr, temp files or process arguments.
- A recording span adds a W3C `traceparent` header to the request. `trace_parent` (or the
  `TRACEPARENT` environment variable, through `host.getenv`) makes the client's spans
  children of a caller's trace.
- Ids are random hex from `host.random`; timestamps are nanoseconds since the epoch built
  from `host.epoch()` and `host.now()` as decimal strings (exact past 2^53). With
  `distilled.host.popen`, `now` is `os.time`, so durations are whole seconds.

## `dl trace` and `dl expect`

```sh
verify/dl trace examples/fake_service.lua [--level debug|operation] [--runtime lua|luajit|rex]
verify/dl trace --file /tmp/neon.jsonl          # the tree of any OTLP/JSON lines file
verify/dl expect examples/fake_service.lua      # run the expect() check the script returns
```

`dl trace` runs a script with a tracer (the script reaches it through
`require("verify.lib.trace_env")`), writes OTLP/JSON lines to `verify/tmp/trace/` and
prints the tree. `dl expect` also runs the assertion function the script returns
against the spans (`e:span("Neon.GetProject"):children("distilled.attempt"):count(3)`;
the full API is in `verify/features/tracing.md`).

## Jaeger

To check that the OTLP output is valid OpenTelemetry, or to browse traces in a UI:

```sh
verify/dl jaeger start     # Jaeger all-in-one in Docker: OTLP HTTP on 4318, UI on 16686
verify/dl jaeger check     # export one trace with otlp_http and find it in Jaeger's query API
verify/dl jaeger stop
```

```lua
local trace = require("distilled.trace")
Neon.new({
  tracing = {
    level = "debug",
    exporter = trace.exporters.otlp_http({ endpoint = "http://localhost:4318",
                                           transport = require("distilled.transport.popen_curl")() }),
  },
})
```

`dl jaeger` exits 3 (skipped) when Docker is not running; on this machine the Docker
daemon was not running for tasks 05 and 07, so the Jaeger round trip has not been run;
the OTLP encoding is covered by specs that decode it back
(`spec/trace_otlp_spec.lua`, `spec/otlp_http_spec.lua` against `dl serve`).
