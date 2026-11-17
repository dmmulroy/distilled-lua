# Task 31: AWS event streams: done

## Built

- `lua/distilled/aws/eventstream.lua`: the message codec. It has the prelude, headers of
  all 10 types, the payload and both CRCs (from the existing `crypto/crc32.lua`, so no
  new file). It also parses and encodes events and signs each event frame with SigV4
  event signing (`:date`, `:chunk-signature`, chained from the prior signature).
- `lua/distilled/stream/aws_eventstream.lua`: reads messages and events from a reader
  (prelude CRC, length limits, truncation as a `ParseError`).
- `lua/distilled/aws/stream.lua` and `aws/protocol.lua`:
  - `protocol.stream(ctx, op, input)` returns the parts `{ status, headers, output, next,
    close, send?, close_input? }`.
  - `event`, `exception` and `error` messages map to union members, the modelled error
    classes and `UnknownAwsError`.
  - `initial-response` fills `stream.output`, and `@eventHeader`/`@eventPayload` members
    are handled.
  - Input events are signed and the empty end frame is sent. The request has the
    `STREAMING-AWS4-HMAC-SHA256-EVENTS` header.
  - A plain call collects an output stream whole and refuses a bidirectional one with
    `SdkError`.
- Generator (`gen/aws.lua`, `gen/ops.lua`): it sets `op.stream = { framing =
  "aws_eventstream", member, item, input? }` and adds the union's errors to `op.errors`.
  21 services in `clients/aws` and `clients/s3` were regenerated. 19 output-only and 10
  bidirectional operations, plus s3 SelectObjectContent, are no longer refused.
- Transports (new files, for task 29 to adopt):
  - `transport/curl_duplex.lua` (shared);
  - `transport/popen_curl_duplex.lua` (stock Lua: curl on FIFOs);
  - `transport/exec_curl_duplex.lua` (an injected `exec.start`, Rex).
  - They are wired into `host/popen.lua` and `host/rex.lua` as `transport.stream` (task
    29's reader contract) and `transport.duplex`. `popen_curl.lua` is untouched.
- `verify/lib/serve_eventstream.py` (hooked into `serve.py`) adds scripted, slow and
  dropped event streams and a duplex echo that verifies signatures, plus a log.
- `verify/lib/aws_eventstream_conform.mjs` writes `spec/golden/aws_eventstream/conform.lua`
  from Distilled's TypeScript and `@smithy/signature-v4`. The aws-sdk-go-v2 vectors are
  in `spec/golden/aws_eventstream/aws-sdk-go-v2`.
- Specs:
  - `aws_eventstream_spec` (52 tests);
  - `aws_eventstream_conform_spec` (19);
  - `aws_eventstream_stream_spec` (21);
  - `aws_eventstream_http_spec` (7, `--http`).
- `verify/lib/aws_call_all.lua` counts the event-stream refusals as expected.
  `verify/features/aws.md` has an "Event streams" section, and `STATUS.md` has section 31.

## Commands run (final)

```
verify/dl doctor                      -> doctor: ok
verify/dl test                        -> lua 2675 passed, 9 pending; luajit 2675 passed,
                                         9 pending; rex 2662 passed, 15 pending
verify/dl test --http                 -> lua 2736 passed; luajit 2736 passed;
                                         rex 2703 passed, 6 pending
verify/dl test --http aws_eventstream_http -> 7 passed on lua, luajit, rex
verify/dl gen-diff aws                -> gen-diff aws: ok (19429/19429 ops built)
verify/dl test s3                     -> 170 passed, 1 pending on each runtime
lua verify/lib/aws_call_all.lua .     -> 19429 ops, 19381 ok, 0 raised, 228 expected, 0 findings
verify/dl rex verify/lib/aws_call_all.lua root=$PWD -> same, 0 findings
git merge main                        -> nothing new (task 29 has not landed)
```

## What is proven

- The codec is byte-exact with aws-sdk-go-v2's positive and negative vectors and with
  Distilled's encodings. A bad CRC is a `ParseError`. Event signatures match
  `@smithy/signature-v4`.
- The replay matches Distilled for 13 output and 4 input streams. It covers the signed
  requests, events, errors, `stream.output`, and the bytes and signatures of input
  frames. Deliberate differences are listed in the spec's `INTENDED` table.
- Incremental delivery against `dl serve`: the first event is in hand while the server
  has sent only one frame, on all three runtimes.
- Full duplex against `dl serve`, on all three runtimes:
  - each event is answered before the next is sent;
  - the server verified every chained signature, including the end frame's;
  - binary payloads arrive intact.
- A dropped connection and an HTTP 400 are handled. `close` kills curl, and no
  processes or temp directories are left.

## Skipped / open

- **`client:<op>_stream` and the Stream object** are task 29's (`client.lua`), which has
  not landed. Until then the parts come from `protocol.stream`; see
  `spec/aws_eventstream_stub.lua`. Task 29 should wrap the parts and pass `output`,
  `send` and `close_input` through (STATUS 31).
- **Live AWS**: no live calls are allowed in tests.
- **HTTP/2 duplex**: measured by hand with curl `--http2-prior-knowledge`, not in a
  spec, because `dl serve` speaks HTTP/1.1 only.
- **`request.timeout`** is not applied to streamed transfers. Deadlines are task 29's.
- **Contract proposals** (STATUS 31) for the orchestrator:
  - `transport.duplex`;
  - the `eof`/`partial` fields on a `read_exact` error;
  - the extra `protocol.stream` part fields;
  - an io.popen exception for `popen_curl_duplex.lua`.
