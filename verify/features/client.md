# Client and operations (`distilled.client`, `distilled.operation`, `distilled.host`)

## Sub-features

- `Client.define{ service, protocol, options, name }` -> class; `Class.new(opts)`,
  `Class.is(v)`. Methods from `service.ops`: `client:<op>(input)`, and for paginated ops
  `client:<op>_pages(input)` / `client:<op>_items(input)`. Collisions, common option names
  reused as provider options, and bad option specs raise in `define`.
- Options: provider options plus `host`, `transport`, `sleep`, `now`, `exec`, `random`,
  `getenv`, `epoch`, `retry`, `deadline_s`, `tracing`, `tracer`, `trace_parent`,
  `validation`, `budget`, `server_hint_cap_s`, `user_agent`. Unknown names and wrong types
  raise, listing the valid names. `client.get_project(x)` (a dot) raises a clear message.
- `client:with{...}`: shallow override; shares budget, credentials cache and tracer
  (unless `tracing`/`tracer`/`trace_parent` is overridden) and the scope.
- `client:close()`: flushes the tracer, closes the scope; returns `true | nil, err`.
- Operation span (`operation.info`, port of `telemetry.ts operationInfo`): name
  `<prefix>.<op>`, `rpc.system.name`, `rpc.method`, `url.template`, label attributes
  `<labels>.<snake_case>`, input/output rules with Distilled's transforms, response header
  rules, `error.type`, `err.trace_id`. Spans are flushed when the outermost call on a
  tracer returns (also after a raise).
- Tracing off: the client holds `distilled.trace.noop`; `distilled.trace` is never loaded.
- `host.merge(base, top)`: top-level fields win; defaults `now = os.time`,
  `epoch = os.time`, `getenv = os.getenv`, a private seeded `random`, a busy-wait
  `sleep`; no default transport (`ConfigError` at call time).

## How a user reaches it

```lua
local neon = Neon.new{ api_key = key, transport = t, tracing = "operation" }
local res, err = neon:get_project{ project_id = "p1" }
local quiet = neon:with{ tracing = "off" }
neon:close()
```

## Driving it with `dl`

- `verify/dl test client_spec` and `operation_spec`: define/new/with/close, option
  checks, tracing forms (file exporter decoded back, traceparent continuation), flushing
  (nested calls, raises, failing exporters), tracing off loading nothing, three golden
  traces in `spec/golden/trace/runtime_*.txt` (regenerate with
  `DL_GOLDEN_WRITE=1 lua spec/run.lua client_spec`).
- `verify/dl trace examples/fake_service.lua --level debug [--runtime rex]` and
  `verify/dl expect examples/fake_service.lua`.

## Gotchas

- `op.span` as a string is the op's model name (Distilled's `{ op = ... }`); the span name
  needs `service.telemetry.prefix`, else it is `op.name`. The task 03 fixture sets
  `span = "Neon.GetProject"` without a prefix, so specs set Neon's telemetry rules.
- A derived client shares the parent's scope: closing either closes it (calls still work).
- Flush failures do not fail calls; `client:close()` reports them.
