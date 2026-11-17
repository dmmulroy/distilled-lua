# Task 29: streaming responses (core): done

## Built

- **Transports.** I did not write a second transport; task 31's process code is
  canonical.
  - `popen_curl(opts)` and `exec_curl(exec, opts)` return callable tables with
    `transport.stream` and `transport.duplex`.
  - On stock Lua the processes are curl on FIFOs (`popen_curl_duplex.lua`). In Rex they
    run over `rex.exec.start` (`exec_curl_duplex.lua`): a stdout callback buffers the
    output and `h:wait(0.05)` drains it.
  - `host/popen.lua` and `host/rex.lua` use these transports directly.
  - Stream timeouts: `request.timeout` bounds only the connection; `request.max_time`
    bounds the whole transfer; `request.idle_timeout` maps to curl `speed-limit` /
    `speed-time`.
  - Reader fixes:
    - a last line cut by a dropped connection is a TransportError, not a line;
    - `close()` waits for the background shell, so no FIFO directory is left behind.
- **`lua/distilled/stream.lua`** has:
  - the Stream object (`next`, `iter`, `collect`, `close`, `send`, `close_input`,
    `status`, `headers`, `output`, `err`);
  - the framing registry;
  - `string_reader`, whose `read_exact` errors carry `eof`/`partial`.
- **Framings.** `stream/ndjson.lua` (frames, plus `collect` for a plain call) and
  `stream/sse.lua` (event-stream parsing as the standard defines it).
- **`protocol/rest.lua`: `protocol.stream`.**
  - A status of 400 or above is read whole and returned as the typed error.
  - Items are decoded as a 2xx body (keys, validation, redaction).
  - A line that is not JSON gives the provider's parse error.
  - A plain call collects an NDJSON reply into `{ items }`.
- **`operation.stream` / `client:<op>_stream(input [, { timeout, idle_timeout }])`** for
  every op with `op.stream`, on REST, gRPC, Connect and AWS.
  - One span covers the whole stream (`distilled.stream.items`, `distilled.stream.end`).
  - Retries happen only before the first item: failures to open, and a TransportError
    before any item. A duplex stream is not peeked.
  - It refreshes credentials on a 401.
  - `connect.as_stream` now returns this Stream.
- **Generator.**
  - New provider key `stream_framing = "ndjson" | "sse"`. With it, `streamWhen` ops get
    `op.stream` with `set_input`, and `serverStreaming` ops get `op.stream` with the
    element of the output's `items` as item.
  - The frame shapes are reachability roots.
  - `types.lua` declares `distilled.Stream<T>` and the `_stream` methods; the README
    marks them `(+ _stream)`.
- **Boat (`providers/boat_dev.lua`, `clients/boat_dev`).**
  - `execute_sandbox_command_stream` sends `stream = true`. `attach_command_stream`
    streams `CommandAttachFrame`s. A plain `attach_command` collects the frames.
  - No generated client has an `unsupported = "streaming"` operation any more.
- **Regenerated:** boat_dev, boxd, modal, aws (16 services), s3. Only types and README
  changed for the last four.
- **`distilled.testing.stream_transport`** (`testing/stream.lua`): a scripted streaming
  transport. Chunks can be strings, error tables (a drop) or functions (to observe the
  moment a chunk is reached).
- **`dl serve`** (`verify/lib/serve.py`):
  - scripted responses with `chunks`/`chunks_b64`, `chunk_delay`, `stall`, `drop_after`
    and `hang`;
  - `GET /_dl/streams` (with `s.streams()` in `verify/lib/serve.lua`).
- **Specs:**
  - `stream_core_spec` (20 tests);
  - `stream_conform_spec` (8 cases against Distilled's TS; golden data from
    `verify/lib/stream_conform.mjs`);
  - `stream_http_spec` (8 tests, `--http`).
- **Docs:** `docs/interfaces.md` has a "Streams" section; there is a new
  `verify/features/streaming.md`; `STATUS.md` has section 29.

## Commands run (final)

```
verify/dl models sync                         -> models sync: 2822 models
verify/dl doctor                              -> doctor: ok
verify/dl test                                -> lua 2751 passed, 10 pending; luajit 2751
                                                 passed, 10 pending; rex 2738 passed, 16 pending
verify/dl test --http                         -> lua 2820 passed; luajit 2820 passed;
                                                 rex 2787 passed, 6 pending
verify/dl test --http stream_http             -> 15 passed on lua, luajit, rex (after the
                                                 last two commits)
verify/dl test --http aws_eventstream_http    -> 7 passed on lua, luajit, rex (now through
                                                 the client's _stream methods)
verify/dl test stream_conform                 -> 47 passed on each runtime (boat 8 + grpc/aws)
verify/dl gen-diff boat-dev | boxd | modal    -> ok, ok, ok
verify/dl gen-diff aws                        -> ok (19429/19429 ops built)
bin/distilled-lua generate (s3)               -> clients/s3 regenerated (types.lua only)
verify/dl conform neon --replay               -> conform: ok
verify/dl conform aws --replay                -> 36 passed on lua, luajit, rex
git merge origin/main                         -> already up to date (30 and 31 merged first)
```

After the full runs, two commits changed only the popen `close()` path and
`stream_http_spec`. I re-ran the `--http` stream specs listed above after them. I did not
re-run the whole suite.

## What is proven

- **Items arrive as the server sends them.** On lua, luajit and Rex, the first item is
  in hand while `dl serve`'s log shows that only one chunk was sent; the next chunk
  follows 1.5 s later. This holds for NDJSON (the generated Boat client), SSE and
  gRPC-Web.
  - In Rex this also works with tracing on, where the stream is opened inside
    `compat.pcall`'s coroutine.
- **Error paths against `dl serve`:**
  - a drop mid-stream gives the items before it, then a TransportError, with no retry;
  - a stalled stream ends at `idle_timeout` with a TimeoutError;
  - a 503 before the body is retried, and the retry streams;
  - a 409 is the typed error from the call;
  - `close()` mid-stream stops curl and leaves no temp directory (popen).
- **Against Distilled's TS** for the same canned bytes, Boat's requests (method, URL,
  body, authorization), items and errors match. The deliberate differences are listed
  in the spec header.

## Skipped / open

- **HTTP trailers of streamed replies** are not exposed: curl writes them after the body
  on the same stream. Task 30 reads them if a transport ever provides them. Proposed fix:
  point `dump-header` at its own fd or FIFO.
- **No live Boat call**: tests may not call live APIs.
- **Proposals for the orchestrator** (STATUS 29):
  - AGENTS.md should name `transport/popen_curl_duplex.lua` as allowed to shell out;
  - `verify/features/README.md` needs a row for `streaming.md`.
