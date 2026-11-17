# Streaming responses (`distilled.stream`, `client:<op>_stream`)

Task 29 (the shared layer); gRPC/Connect framing is task 30 (`grpc.md`), AWS event
streams task 31 (`aws.md`). The contract is in `docs/interfaces.md`, section "Streams".

## Sub-features

- **Transports.** `transport.stream(request) -> { status, headers, body = reader }` on
  `popen_curl(opts)` (curl in the background on FIFOs, `transport/popen_curl_duplex.lua`)
  and `exec_curl(exec, opts)` when `exec.start` exists (`rex.exec.start`, stdout pieces
  drained with `h:wait(0.05)`, `transport/exec_curl_duplex.lua`). Readers: `read_line`,
  `read_exact` (`err.eof`/`err.partial` for a body cut inside a frame), `read_all`,
  `close` (kills curl, removes the FIFO directory; idempotent). `transport.duplex` for AWS
  input streams. Stream timeouts: `request.timeout` = connect, `max_time`, `idle_timeout`.
- **Stream object** (`distilled.stream`): `next`, `iter` (`false, err` once), `collect`,
  `close`, `status`, `headers`, `output`, `err`, `send`/`close_input` (duplex).
- **Client**: `client:<op>_stream(input [, { timeout, idle_timeout }])` for every op with
  `op.stream`; one span over the stream (`distilled.stream.items`, `distilled.stream.end`);
  retry under the op's policy only before the first item (open failures and a
  `TransportError` before any item); refresh-on-401.
- **Framings**: NDJSON (`stream/ndjson.lua`: non-empty lines; `collect` for a plain call),
  SSE (`stream/sse.lua`: the standard's parsing: data joined, comments, `event`, `id`,
  `retry`, no-data events dropped); `grpc`, `connect`, `aws_eventstream` by their
  protocols. `stream.register_framing(name, fn)` for a provider's own.
- **REST protocol**: `protocol.stream(ctx, op, input)`; status >= 400 read whole and
  decoded as the typed error; items decoded like a 2xx body (keys, validation, redaction);
  a non-JSON NDJSON line is the provider's parse error.
- **Generator**: `stream_framing = "ndjson" | "sse"` in a REST provider spec: `op.stream`
  for `streamWhen` (`set_input`, Distilled's `streamInput`) and `serverStreaming` ops;
  LuaLS `distilled.Stream<T>` types and `(+ _stream)` in the README.
- **Boat** (`clients/boat_dev`): `execute_sandbox_command_stream` (sends `stream = true`),
  `attach_command_stream`; plain `attach_command` collects `{ items }`. No generated client
  has an `unsupported = "streaming"` operation any more.

## How a user reaches it

```lua
local boat = require("boat_dev").new({ host = require("distilled.host.popen")() })
local stream, err = boat:execute_sandbox_command_stream({ sandboxId = id, command = "make" })
if not stream then return nil, err end
for frame, ferr in stream:iter() do
  if ferr then return nil, ferr end
  if frame.type == "stdout" then io.write(frame.data) end
end
```

## Driving it with `dl`

- `verify/dl test stream_core`: Stream object, framings, Boat over the scripted streaming
  transport (incremental pulls, retry before the first item, no retry after, typed
  errors, parse errors, spans, timeouts).
- `verify/dl test stream_conform`: Boat's streams vs Distilled's TS for 8 canned replies
  (`verify/lib/stream_conform.mjs` writes `spec/golden/stream/boat.json`).
- `verify/dl test --http stream_http`: against `dl serve` on lua, luajit and Rex: the
  first item is in hand while the server has sent one chunk (NDJSON, SSE, gRPC-Web), a
  drop mid-stream, a stall ending at `idle_timeout`, a 503 retried, a 409, close mid-way.
- `dl serve` scripts: `{ chunks = {...}, chunk_delay, stall, drop_after, hang }`,
  `GET /_dl/streams`.

## Gotchas

- `<op>_stream` returns after the first item (or the end) arrived: that is where retry
  stops. A stream whose first item takes long blocks the call that long.
- Lua cannot see a `break`: call `stream:close()` when leaving a loop early, or curl keeps
  running until the process exits and the span stays open.
- HTTP trailers of a streamed reply are not exposed (curl writes them after the body on
  the same stream); a gRPC (HTTP/2) stream without a trailer status counts as OK, as with
  fetch.
- `request.timeout` bounds only the connection for streams; use `timeout` /
  `idle_timeout` for the transfer.
