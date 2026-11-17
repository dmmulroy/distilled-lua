# Task 29: streaming responses (core)

Read `AGENTS.md`, `STATUS.md` and `tasks/10-parity-overview.md` first. Today every call is
"send a request, get one whole body back". Operations whose replies arrive piece by piece
are refused or collected whole: boat-dev's NDJSON `ExecuteSandboxCommand` stream
(`op.unsupported = "streaming"`), gRPC server streams (modal 13, boxd 4, boat-dev 1:
collected whole, so a never-ending log stream only ends at the timeout), AWS event
streams (~30 operations refused), e2b Connect server streams (not ported). Distilled's
TS: `API.makeStreaming`, `.stream()` in `core/src/api.ts`, `protocol-rest.ts` (framing),
`core/src/ndjson.ts`, `protocol-grpc.ts`.

You build the shared layer. Tasks 30 (gRPC/Connect streams) and 31 (AWS event streams)
run in parallel and code against the contract below; keep it exactly, or record a change
in STATUS.md at once and tell them through it.

## The contract (fixed by the orchestrator)

```lua
-- transport: optional second entry point; a transport without it cannot stream
local res, err = transport.stream(request)   -- request as today
-- res = { status, headers, body = reader }  (headers complete before the body)
-- reader:read_line()   -> line without "\n" (strips a trailing "\r") | nil, nil at EOF | nil, err
-- reader:read_exact(n) -> exactly n bytes | nil, nil at clean EOF before any byte | nil, err
-- reader:read_all()    -> rest of the body | nil, err
-- reader:close()       -> stops the process / connection; idempotent
-- err: distilled.errors tables (TransportError, TimeoutError ...), never raised

-- client surface, for an op with op.stream = { framing = "ndjson" | "sse" | "grpc"
-- | "aws_eventstream" | "connect", item = <schema node> }
local stream, err = client:execute_sandbox_command_stream(input)
for item, item_err in stream:iter() do ... end     -- item_err ends the loop
stream:close()
-- also: stream.status, stream.headers; stream:next() -> item | nil, nil (end) | nil, err
```

## Files you own

```text
lua/distilled/stream.lua (new)         reader helpers, Stream object, framing registry
lua/distilled/stream/ndjson.lua, sse.lua (new)
lua/distilled/transport/popen_curl.lua, exec_curl.lua   the `stream` entry point
lua/distilled/host/rex.lua             rex.exec.start-based streaming (stdout callback
                                       buffered, drained with h:wait(0.05) in read_*)
lua/distilled/testing/*                a scripted streaming transport (chunks, delays, errors)
lua/distilled/client.lua, operation.lua, protocol/rest.lua   `_stream` methods, tracing
                                       (one span covering the stream), retry only before
                                       the first item, deadline/timeout, redaction of items
lua/distilled/gen/*                    emit op.stream for streamWhen / makeStreaming ops;
                                       stop emitting op.unsupported = "streaming" for them
verify/lib/serve.py                    endpoints that stream slowly (chunked, SSE, NDJSON,
                                       binary frames), stall, and drop mid-stream
providers/boat_dev.lua, clients/boat_dev/ (regenerate)
spec/stream_*_spec.lua, verify/features/streaming.md, docs/interfaces.md (stream section)
STATUS.md (section "29 streaming-core")
```

## Requirements

1. Measured facts first (put them in STATUS.md): popen `f:read("*l")` and `f:read(n)`
   return as soon as data arrives (curl `-N`, headers with `-i` or `-D` to a fd); in Rex,
   `rex.exec.start` stdout pieces arrive incrementally while the script sits in
   `h:wait(0.1)` (the orchestrator saw lines 1 s apart arrive 1 s apart). Secrets stay
   out of argv (config on stdin/file, as today).
2. Items are delivered as they arrive: a spec against `dl serve` proves the first item
   is read before the server sends the second (all three runtimes, `dl test --http`).
3. Errors: non-2xx before the body -> the usual error classes (whole body read);
   a mid-stream transport drop or a framing error -> `nil, err` from the iterator, and
   `close()` always reaps the process. No retry after the first item.
4. boat-dev's stream operation works end to end against the fixture server, and its
   requests/items match Distilled's TS for the same canned bytes.
5. `verify/dl gen-diff` for every package you regenerate; conformance replays green.
Push `task-29` after every meaningful step.
