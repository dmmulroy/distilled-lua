# Task 30: incremental gRPC server streams and Connect server streams

Read `AGENTS.md`, `STATUS.md` (23, 29), `verify/features/grpc.md` and
`tasks/29-streaming-core.md` (the reader/Stream contract; task 29 builds it in parallel:
code against the contract, `git merge main` once it lands, and until then test with a
local stub reader). Today gRPC server streams (modal 13, boxd 4, boat-dev 1) are collected
from one whole response into `{ items = {...} }`; e2b's Connect server streams
(`../distilled/packages/e2b/src/connect.ts`) are not ported.

## Files you own

```text
lua/distilled/stream/grpc.lua, stream/connect.lua (new)   framing decoders on a reader
lua/distilled/protocol/grpc.lua, protocol/connect.lua     the streaming paths
lua/distilled/gen/proto.lua (and gRPC parts of gen/)      op.stream for server streams
providers/modal.lua, boxd.lua, e2b.lua, namespacelabs.lua; their clients/ (regenerate)
spec/grpc_stream_spec.lua, spec/connect_stream_spec.lua; verify/features/grpc.md
STATUS.md (section "30 grpc-streams")
```

## Requirements

1. Server-streaming methods get `client:<op>_stream(input)` returning a Stream whose
   items are decoded messages as each 5-byte-prefixed frame arrives; grpc-status from
   trailers (or a trailers-only reply) ends the stream with an error when non-zero.
   Keep the existing collected form, as Distilled keeps both, if it does.
2. e2b Connect server streams (envelope flags, end-stream message with error/metadata)
   ported from `connect.ts`, with its process/filesystem watch operations callable.
3. Prove incremental delivery against `dl serve` (frame 1 read before frame 2 is sent),
   mid-stream errors, trailers-only errors; compare bytes/items with Distilled's TS for
   the same canned responses. All three runtimes.
Push `task-30` after every meaningful step.
