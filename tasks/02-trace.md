# Task 02: tracing

You build the tracer, its exporters, and the two verification commands that read traces.
Task 01 (harness, `verify/dl`, json, errors, secret, scope) is finished; build on it. Task 03
(schema and request building) runs at the same time as you in this working tree, so stay
inside your files.

Read `AGENTS.md`, then the "Tracing" and "Scope" sections of `../distilled-lua-plan.md`, then
the tracer contract in `docs/interfaces.md`. Reference: `../distilled/packages/core/src/telemetry.ts`,
`telemetry-debug.ts` and `../distilled/packages/dev/src/codegen/telemetry-traits.md`.

## Files you own

```text
lua/distilled/trace/init.lua            tracer, noop tracer, span, id and time helpers
lua/distilled/trace/otlp.lua            spans -> OTLP/JSON (resourceSpans / scopeSpans / spans)
lua/distilled/trace/exporters.lua       memory, file, console   (otlp_http is task 06)
lua/distilled/trace/tree.lua            spans -> indented text tree (used by console and dl)
lua/distilled/trace/expect.lua          assertions over a list of spans
verify/dl: the `trace` and `expect` commands only (replace the stubs; touch nothing else in it)
verify/lib/trace_*.lua   verify/features/tracing.md
spec/trace_*_spec.lua   spec/golden/trace/*
STATUS.md (your section)
```

## Requirements

1. **Tracer and spans**, per the contract.
   - The core is synchronous, so the current span is a stack inside the tracer.
     `tracer:with` must end the span when `fn` returns normally, returns `nil, err` (mark
     the span failed with `error.type = err.tag`, then return `nil, err` unchanged), or
     raises (mark failed, end, re-raise the original value).
   - `trace.noop` has every method and allocates nothing per call. Code that uses a tracer
     must not need to branch on whether tracing is on.
   - Level `operation` records spans started without `debug = true`; level `debug` records
     all. A debug span started under level `operation` returns a non-recording span whose
     methods are no-ops, and children started under it attach to the nearest recording ancestor.
   - Trace ids are 32 lowercase hex characters, span ids 16, never all zero, built from
     `host.random` in chunks small enough to be exact in float64.
   - Timestamps: OTLP needs nanoseconds since the Unix epoch, which exceeds float64
     precision. Take `host.epoch()` once when the tracer is created and `host.now()` for
     offsets, and build the decimal string with integer arithmetic on seconds and
     nanoseconds separately. Test with a fake host that it is exact and monotonic.
   - `tracer:traceparent()` returns `00-<trace_id>-<span_id>-01` for the current recording
     span. `parent` accepts an incoming traceparent and continues that trace; reject a
     malformed one by ignoring it.
   - Attribute values: strings, numbers, booleans, and arrays of those. A secret
     (`distilled.secret`) passed as a value is recorded as `<redacted>`. Anything else is
     converted with `tostring`.
   - Spans are buffered and handed to exporters on `tracer:flush()`. An exporter failure is
     returned from `flush` and must never fail or raise into the traced call.
2. **OTLP/JSON** (`otlp.lua`): exactly the OTLP JSON encoding (hex ids, `startTimeUnixNano`
   as a string, `kind` as the enum number, attributes as `{ key, value = { stringValue |
   intValue (string) | doubleValue | boolValue | arrayValue } }`, status code numbers,
   `resource` with `service.name`, scope name `distilled-lua`). Check your output against the
   OTLP specification (fetch it); do not guess field names.
3. **Exporters:** `memory()` (returns the exporter and exposes `.spans`), `file{ path,
   max_bytes }` (one OTLP/JSON `resourceSpans` object per line, appended; when the file
   exceeds `max_bytes`, truncate before writing), `console{ write }` (the tree).
4. **Tree** (`tree.lua`): children indented under parents in start order, each line with
   name, duration in ms, status, and attributes inline (sorted keys); failed spans marked.
   Deterministic for a given span list.
5. **`expect.lua`**: a small assertion API over spans that task 05 onward uses in specs, e.g.
   `expect(spans):span("Neon.GetProject"):attr("http.response.status_code", 200)`,
   `:children("distilled.attempt"):count(3)`, `:failed("TooManyRequests")`,
   `:no_attr_contains("sk-CANARY")` (searches every attribute, event and status message of
   every span). Failures say which span and what was found. You design the exact API;
   document it in `verify/features/tracing.md` and keep it small.
6. **Golden traces:** a normaliser that replaces ids and timestamps with stable placeholders
   (`trace-1`, `span-1`, durations dropped) so a tree can be compared with a committed file.
7. **`dl trace <script.lua> [--level debug|operation] [--runtime lua|luajit|rex]`**: runs the
   script with a tracer installed where the script can reach it, writes the OTLP file to a
   temp path, prints the tree. `dl trace --file <path>` prints the tree of an existing file.
   **`dl expect <script.lua>`** runs a script that returns or performs `expect` assertions
   and exits non-zero on failure. Decide how a script receives the tracer (for example a
   module `verify.lib.trace_env` it requires) and document it. Both must work under all
   three runtimes; under Rex there is no `io.popen`, and file writes use `io.open`.

Until tasks 04-05 exist there is no client to trace, so your specs and example scripts
create spans by hand (simulate an operation with three attempts, a backoff and a failure).

## Done means

- `verify/dl doctor` clean, `verify/dl test` green in all three runtimes, including your specs.
- `verify/dl trace` on your example script prints a correct tree under each runtime; paste
  the three outputs in `tasks/02-trace.done.md`.
- A sample OTLP/JSON line is in the done file, with a note on how you checked it against
  the specification.
