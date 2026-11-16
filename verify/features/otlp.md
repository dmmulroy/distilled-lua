# OTLP/HTTP export (`distilled.trace.otlp_http`) and `dl jaeger`

## Sub-features

- `require("distilled.trace.otlp_http"){ endpoint, transport, headers, timeout = 5,
  service_name }`, also `trace.exporters.otlp_http{...}`: an exporter `fn(spans, meta) ->
  true | nil, err` that POSTs one OTLP/JSON ExportTraceServiceRequest
  (`distilled.trace.otlp.encode`) to `<endpoint>/v1/traces` (kept as is when the endpoint
  already ends in `/v1/traces`).
- Untraced: it calls the transport directly, never a traced client, so an export makes no
  spans.
- Failures are returned as `SdkError` (transport failure with `err.cause`, non-2xx with
  `err.status` and the first 200 bytes of the body, `partialSuccess.rejectedSpans > 0`),
  never raised; the tracer reports them from `flush()` as "trace export failed: ...".
- `headers` values may be secrets (unwrapped when sent); messages never contain header
  values, or the endpoint's userinfo or query.
- Without `transport`, it uses `opts.host.transport`, else popen_curl (stock Lua only; in
  Rex pass `host.transport`).

## How a user reaches it

```lua
local host = require("distilled.host.rex")()
local client = Neon.new{ host = host, tracing = { level = "operation",
  exporter = trace.exporters.otlp_http{ endpoint = "http://127.0.0.1:4318", transport = host.transport } } }
```

## Driving it with `dl`

- `verify/dl test otlp_http` (offline: URL, body decodes back with `otlp.decode`, secret
  headers, non-2xx, partial success, untraced flush) and `--http` (dl serve receives a
  decodable export; 415 and refused are returned).
- `verify/dl jaeger start|stop|url|check`: Jaeger all-in-one in Docker
  (`DL_JAEGER_IMAGE`, default `jaegertracing/all-in-one:latest`), OTLP HTTP on
  127.0.0.1:4318, UI and query API on 127.0.0.1:16686. `check` exports one trace
  (`verify/lib/jaeger_check.lua`) and polls `/api/traces/<id>`. Exit 3 when Docker is not
  running; dl never starts Docker.

## Gotchas

- OTLP int64 fields are strings in JSON, so `rejectedSpans` may arrive as `"1"`.
- Jaeger before 1.35 needed `COLLECTOR_OTLP_ENABLED=true`; `dl jaeger start` sets it.
