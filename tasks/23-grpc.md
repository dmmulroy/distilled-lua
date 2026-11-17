# Task 23: gRPC and Connect (modal, boxd, e2b, namespacelabs)

Read `tasks/10-parity-overview.md` and `STATUS.md` (sections 10-15, especially 12:
streaming ops are emitted with `op.unsupported = "streaming"`) first.

modal and boxd are proto3 models served as binary gRPC (Modal's envoy accepts plain
HTTP/1.1, see `../distilled/packages/modal/src/protocol.ts`); e2b and namespacelabs use
Connect and/or REST (`src/connect.ts`, `src/protocol.ts`). Core: `protocol-grpc.ts`,
`protobuf.ts`, `grpc-transport*.ts`, `hpack.ts`. Generated descriptors: each package's
`src/descriptors.ts` (from its generate script).

## Files you own

```text
lua/distilled/protobuf.lua (new)          proto3 binary encode/decode from descriptors
lua/distilled/protocol/grpc.lua (new)     unary gRPC over the transport (HTTP/1.1 or curl --http2)
lua/distilled/protocol/connect.lua (new)  if e2b/namespacelabs need it
lua/distilled/gen/*                        ONLY descriptor emission for proto models
                                           (new file gen/proto.lua preferred)
lua/distilled/transport/*.lua             ONLY what gRPC needs (http2 flag, trailers, binary bodies)
providers/modal.lua, boxd.lua, e2b.lua, namespacelabs.lua (new)
clients/modal/, clients/boxd/, clients/e2b/, clients/namespacelabs/ (generated, committed)
spec/protobuf_spec.lua, spec/grpc_spec.lua, verify/features/grpc.md
STATUS.md (section "23 grpc")
```

## Requirements

1. protobuf: varints (64-bit values beyond 2^53 as strings or a documented
   representation; mirror Distilled's choice for int64 in proto3 JSON), zigzag, fixed32/64,
   doubles/floats (pure Lua IEEE-754 packing; no string.pack), length-delimited,
   packed repeated, maps, oneofs, enums, nested messages, unknown fields skipped. Round-trip
   tests against `protobuf.ts` through Node.
2. Unary gRPC: one length-prefixed frame, `content-type: application/grpc`, `te: trailers`,
   grpc-status / grpc-message from headers or trailers (curl: check what popen_curl /
   exec_curl can see; trailers-only responses), status -> error class mapping as Distilled.
   Streaming ops stay unsupported unless server streaming over one HTTP response is easy
   to add; say which.
3. Each package's auth and headers from its TS glue (Modal: token id/secret headers,
   client version headers, ...).
4. Fixture-server tests for success, gRPC error, transport error and retry paths.
