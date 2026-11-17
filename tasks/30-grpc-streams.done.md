# Task 30: grpc-streams — done (one item blocked on task 29)

## Built

- `lua/distilled/stream/grpc.lua`: gRPC frames read one at a time from a reader (`read_exact`). It
  collects gRPC-Web trailer frames (0x80), refuses compressed frames, and records `rest` for an
  incomplete last frame (a clean EOF, or a `read_exact` err with `eof = true`).
- `lua/distilled/stream/connect.lua`: Connect envelopes (flags, be32 length, JSON; 0x02 marks
  end-of-stream). Invalid JSON becomes `{ __invalidJson }` as in connect.ts; a cut envelope is a
  ParseError.
- `protocol/grpc.lua`: `protocol.stream(ctx, op, input) -> parts{status, headers, next, close}, nil, meta | nil, err, meta`.
  The collected form (`{ items }`) is kept.
  - A non-gRPC reply and a trailers-only status fail before the first item, so they can be retried.
  - Statuses from transport trailers or the gRPC-Web trailer frame end the stream (typed error).
  - A transport drop gives the transport's error.
  - A truncated frame after an OK status is INTERNAL.
  - Each item is decoded through the output schema, so sensitive members are wrapped.
  - `protocol.call` was refactored onto a shared `send`.
- `protocol/connect.lua`: `connect.stream`, `connect.stream_method{ op, fail, decode }` and a
  minimal Stream object (`next`, `iter`, `close`, `status`, `headers`).
- e2b (`providers/glue/e2b_envd.lua`, regenerated `clients/e2b`): `start_process_stream` and
  `connect_process_stream` on `e2b.process`, `watch_dir_stream` on `e2b.filesystem`. They port
  decodeProcessEvent, decodeWatchDirEvent, connectError and serverStream's pre-stream mapping.
- gen: `op.stream = { framing = "grpc", item = S.ref(msg) }` for gRPC server streams (modal 13,
  boxd 4; clients regenerated). New glue hook `methods` (gen/provider_ext.lua + gen/writer.lua).
- Specs:
  - `spec/grpc_stream_spec.lua` (17)
  - `spec/connect_stream_spec.lua` (11)
  - `spec/grpc_stream_conform_spec.lua` (20 cases from Distilled's TS, made by
    `verify/lib/grpc_stream_conform.mjs` → `spec/golden/grpc_stream/conform.json`; they compare
    request URL, headers and body bytes, items and error tag/message/fields)
  - helper `spec/grpc_stream_stub.lua` (stub reader and stream transport)
- `verify/features/grpc.md` updated.

## Commands run

- `verify/dl models sync` → 2822 models
- `verify/dl doctor` → doctor: ok
- `verify/dl test` → lua 2631 passed / 8 pending; luajit 2631 / 8; rex 2618 / 14
- `verify/dl test grpc_stream_spec|connect_stream_spec|grpc_stream_conform_spec|grpc_spec` → all ok in all three runtimes
- `verify/dl gen-diff boxd` → ok; `verify/dl gen-diff modal` → ok
- `verify/dl gen-diff e2b`: diff, stylua and gen-check of the 16 services are all ok. The command still reports FAIL because `verify/dl` takes e2b's `unstable` model for a GCP second index (pre-existing, not from this task).
- I broke the golden file on purpose (item, error field, request bytes) and the conformance spec failed in all three cases.

## Skipped / blocked

- **Incremental delivery against `dl serve`** (frame 1 read before frame 2 is sent) is not done. It needs task 29's `transport.stream`, its slow-streaming serve.py endpoints and the Rex streaming host. None of them exist on main or on task-29's branch (no commits). Incremental delivery is proven only with the lazy stub reader: the spec checks that chunk 2 is not pulled before item 1 is returned (gRPC and Connect).
- **`client:<op>_stream` for the gRPC ops** waits on task 29's client.lua. The ops carry `op.stream`, and the conformance spec calls `protocol.stream` directly until the method exists (it switches automatically). The e2b stream methods already work today through the glue.
- No modal TS conformance case: boxd covers the shared streamReply path, and modal's HTTP-trailer path is covered by the stub spec.

## Open problems / proposals for task 29 (in STATUS.md, section 30)

- The protocol entry point `protocol.stream(ctx, op, input)` returns parts. operation.lua should wrap them in the Stream object (span, retry before the first item).
- `read_exact` at EOF mid-read should return an err with `eof = true, partial = n`.
- Streamed-reply trailers should be exposed as `res.trailers`, `reader.trailers` or `reader:trailers()` once the body has ended.
- After merging task 29, replace `connect.as_stream` with task 29's Stream, and add a `--http` spec against slow serve endpoints.
