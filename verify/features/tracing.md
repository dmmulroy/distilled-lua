# Tracing (`distilled.trace`)

## Sub-features

- **Tracer** (`trace.new{ level, exporter, host, service_name, parent }`): the current span
  is a stack inside the tracer (the core is synchronous). `tracer:start(name, { kind,
  attributes, debug })` pushes, `span:finish()` pops; finishing a span also ends children
  still open under it. `tracer:current()`, `tracer:traceparent()`, `tracer:flush()`.
- **`tracer:with(name, opts, fn)`**: ends the span on a normal return (all results passed
  through), on `nil, err` (span failed, `error.type = err.tag`, `nil, err` returned
  unchanged; `err` is not modified) and on a raise (failed, ended, original value
  re-raised with `error(v, 0)`). Runs `fn` in a coroutine, not `pcall` (see Gotchas), so a
  yield inside `fn` passes through to the caller's coroutine.
- **Levels**: `operation` records spans started without `debug = true`; `debug` records
  all. A debug span under `operation` is the shared non-recording `trace.NOOP_SPAN`; spans
  started inside it attach to the nearest recording ancestor, and `traceparent()` names
  that ancestor.
- **`trace.noop`**: same methods, `level == "off"`, allocates nothing per call
  (`noop:with(name, opts, fn)` is `fn(trace.NOOP_SPAN)`). Both noop tables are write-proof.
- **Ids**: trace 32 / span 16 lowercase hex, from `host.random` in 16-bit chunks; never all
  zero. Each root span starts a new trace unless `parent` was given.
- **Time**: `host.epoch()` is read once at creation, `host.now()` gives offsets; the
  nanosecond string is assembled from whole seconds and nanoseconds separately (exact past
  2^53), and never goes backwards. `trace.ns_diff_ms(a, b)` subtracts two such strings.
- **Propagation**: `traceparent()` is `00-<trace>-<span>-01` for the current recording
  span. `parent` accepts a W3C traceparent (lowercase hex, version not `ff`, no all-zero
  ids, version `00` exactly four fields); a malformed one is ignored.
  `trace.parse_traceparent(s)` is exposed.
- **Attribute values**: strings, numbers, booleans, lists of those (plain sequences or
  `json.array`-marked); a secret becomes `<redacted>` (also in lists, events and the
  status message of `span:fail(secret)`); anything else goes through `tostring`.
  `span:set(k, nil)` removes; non-string keys are ignored.
- **Flush**: finished spans go to every exporter in start order as
  `exporter(spans, { service_name })`. A failing or raising exporter makes `flush` return
  `nil, SdkError` (all messages joined); the other exporters still run, the traced call is
  never affected.
- **OTLP/JSON** (`distilled.trace.otlp`): `encode(spans, { service_name })` (an
  ExportTraceServiceRequest table), `encode_line`, `decode(doc)`, `decode_lines(text)`,
  `any_value(v)`. Hex ids, `kind` and `status.code` as integers, 64-bit values as decimal
  strings (`intValue` for integral numbers below 2^53, `doubleValue` otherwise, and
  `"NaN"` / `"Infinity"` / `"-Infinity"`), `resource.service.name`, scope `distilled-lua`.
- **Exporters** (`distilled.trace.exporters`, also `trace.exporters`): `memory()` (a
  callable table: `.spans`, `:clear()`), `file{ path, max_bytes, service_name }` (one
  `{"resourceSpans":[...]}` line per flush, appended; truncated first once the file is
  larger than `max_bytes`; only `io.open`), `console{ write, durations }` (the tree).
- **Tree** (`distilled.trace.tree`): `render(spans, { durations })`, `order(spans)`,
  `normalize(spans)`, `golden(spans)`. A `trace <id>` header per trace (plus
  `(parent <id>)` for a remote parent), then spans indented under parents in start
  order, with the span's events (`@ name +Xms attrs`) merged among its children by time.
  Line: name, kind (omitted when internal), duration, `unset` | `ok` | `ERROR "<message>"`,
  attributes sorted by key (strings bare unless they need quotes; arrays as `[a,b]`).
- **Golden traces**: `tree.golden` renames ids to `trace-N` / `span-N` / `remote-N` in tree
  order (also inside string values, such as a recorded traceparent), replaces each
  timestamp by its rank, and drops durations.
- **Assertions** (`distilled.trace.expect`): below.

## The `expect` API

```lua
local expect = require("distilled.trace.expect")
local e = expect(memory_exporter)          -- or expect(list_of_spans): selects every span
```

A selection is a list of spans. Selectors return a new selection; assertions check every
span in the selection and return it, so calls chain. A failed assertion raises a string
(at the caller's line) naming the selection, what was expected, and `found:` tree lines
of the offending spans.

| Call | Meaning |
| --- | --- |
| `sel:span(name)` | the one span named `name` among the selection and its descendants; fails on 0 or more than 1, listing the names present |
| `sel:spans([name])` | every such span (0 or more) |
| `sel:children([name])` | direct children of each selected span, in start order |
| `sel:parent()` | the parent of each (fails for a root) |
| `sel:nth(i)` | the i-th selected span |
| `sel:count(n)` | exactly n spans selected |
| `sel:attr(key [, value])` | attribute present (and equal; lists compare element-wise) |
| `sel:no_attr(key)` | attribute absent |
| `sel:failed([tag])` | status error (and `error.type == tag`) |
| `sel:ok()` | status not error |
| `sel:event(name [, attrs])` | has an event with that name (whose attributes include `attrs`) |
| `sel:no_attr_contains(needle)` | plain substring in no span name, attribute key or value, event name or attribute, or status message, of the selection and all descendants |
| `sel:list()`, `sel:get([i])`, `sel:tree([opts])` | the raw records, one record, the rendered subtree |

```lua
e:span("Neon.GetProject"):attr("http.response.status_code", 200)
e:span("Neon.GetProject"):children("distilled.attempt"):count(3)
e:span("Neon.GetProject"):failed("TooManyRequests")
e:no_attr_contains("sk-CANARY")
```

## How a user reaches it

```lua
local trace = require("distilled.trace")
local mem = trace.exporters.memory()
local tracer = trace.new{ level = "debug", exporter = { mem, trace.exporters.file{ path = p } },
                          host = host, service_name = "neon" }
local value, err = tracer:with("Neon.GetProject", { kind = "client" }, function(span)
  span:set("http.response.status_code", 200)
  return value
end)
tracer:flush()
```

Until tasks 04-05, clients do not create spans; tracing is used directly as above.

## Driving it with `dl`

- `verify/dl test trace_` runs `spec/trace_{tracer,otlp,exporters,tree,expect}_spec.lua`
  under all three runtimes.
- `verify/dl trace <script.lua> [--level debug|operation] [--runtime lua|luajit|rex]` runs
  the script with a tracer, writes OTLP/JSON lines to
  `verify/tmp/trace/<script>-<runtime>.jsonl` and prints the tree. Default level `debug`,
  default runtime `lua`. Exit 1 when the script raises.
- `verify/dl trace --file <path> [--runtime R]` prints the tree of an OTLP/JSON lines file.
- `verify/dl expect <script.lua> [--level L] [--runtime R]` runs the script like `trace`;
  when the script returns a function, it is called as `fn(expect(spans), spans)`. Exit 1
  when the script raises or an assertion fails. A script may also assert directly with
  `env.expect()` (which flushes first).
- Example: `verify/lib/trace_example.lua` (a simulated Neon.GetProject: 429, 429, 503, two
  backoffs, a recorded secret); `verify/lib/trace_example_failing.lua` must exit 1.
- Golden trees: `spec/golden/trace/*.txt`, cases in `verify/lib/trace_golden_cases.lua`,
  regenerate with `lua verify/lib/trace_golden.lua` from the repository root and review
  the diff.

**How a script receives the tracer:** `local env = require("verify.lib.trace_env")`.
`env.tracer` is the installed tracer, `env.host` a host on a virtual clock
(`env.host.sleep(s)` advances time immediately and records the wait, `env.host.advance(s)`
moves time without recording), `env.spans()` flushes and returns every exported span,
`env.expect()` is `expect(env.spans())`, `env.tracer.level` tells the level. The runner
(`verify/lib/trace_run.lua`) calls `env.install{ level, file }` before loading the script;
a script run without the runner gets a debug tracer with only a memory exporter.

For specs, `verify/lib/trace_fake_host.lua` is a fully deterministic host (fixed epoch,
fake clock, seeded Park-Miller random) and `verify/lib/trace_sim.lua` the simulated call.

## Gotchas

- **gopher-lua, nested protected calls**: once a `pcall`/`xpcall` has *completed* inside
  another protected call, the outer one catching an error breaks the upvalues of closures
  in running frames (counter stays 0). `compat.pcall` (xpcall) is affected in that nested
  case. A coroutine that catches an error is not, so `tracer:with` and `flush` protect
  with `coroutine.resume` (about 2.6 µs per call in Rex). Consequence: a raise through
  `with` loses the original traceback (the message keeps its position).
- Timestamps: never compute `epoch * 1e9` in a float. Compare ns strings by length then
  text; `trace.ns_diff_ms` subtracts them exactly enough for display.
- `os.clock` is CPU time in lua/luajit and wall time in Rex; the `dl trace` env adds a
  virtual offset for sleeps, so its durations show backoff but not real waits on lua.
- LuaJIT seeds `math.random` identically every run; the default tracer uses
  `math.random`, so give a real host (task 05) a better random source. The `dl` env seeds
  from the time.
- The memory exporter is a callable table, not a function: call sites must not check
  `type(exporter) == "function"`.
- Status on success stays `unset` (OTel guidance for instrumentation libraries); only
  failures set a status.
