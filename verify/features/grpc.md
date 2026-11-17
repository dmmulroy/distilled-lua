# gRPC, gRPC-Web and Connect (`distilled.protobuf`, `distilled.protocol.grpc`, `distilled.protocol.connect`)

Task 23 adds proto-sourced providers: modal (binary gRPC) and boxd (gRPC-Web). e2b and
namespacelabs (Connect JSON, which is plain REST) use the REST provider specs of tasks 13 and 27
(merged from main); task 23 generated and tests their clients. The `proto` wire `connect`
(`distilled.protocol.connect`) stays available for a Connect provider that needs it.

## Sub-features

- **`distilled.protobuf`** is a proto3 binary codec over Distilled's descriptor tables. It ports `core/src/protobuf.ts`.
  - `encode(d, name, value)` and `decode(d, name, bytes)` work on proto3 JSON-shaped values.
  - 64-bit integers are decimal strings.
  - Enums travel as names, or as numbers when unknown.
  - Bytes travel as base64.
  - Maps and packed repeated fields are supported.
  - `optional` presence is supported, and so is `oneof` presence via the descriptor's `presence` flag.
  - Well-known types are supported: Timestamp, Duration, Struct, Value, ListValue, FieldMask, Any, the wrappers and Empty.
  - `frame(payload [, flag])` and `unframe(body) -> { messages, trailers, rest }` handle gRPC message framing.
  - Failures return `nil, err`:
    - InvalidInput (`protobuf = "ProtobufEncodeError"`, `member`);
    - ParseError (`ProtobufDecodeError`, `ProtobufJsonRangeError`).
  - Nesting is limited to `MAX_DEPTH = 100` because of gopher-lua's call stack.
- **`distilled.protocol.grpc`** handles unary calls and server streams, built on the REST protocol. It ports `core/src/protocol-grpc.ts`.
  - **Request:** one frame.
    - gRPC: `content-type: application/grpc` and `te: trailers`.
    - gRPC-Web (`web = true`): `application/grpc-web+proto` and `x-grpc-web: 1`.
    - `http2 = true | fn(creds)` sets `request.http2`.
  - **Status:** read from HTTP trailers, then from a gRPC-Web trailer frame, then from the headers (a trailers-only reply).
    - `grpc-message` is percent-decoded.
    - Message frames with no status count as OK.
  - **Errors:** a non-zero status becomes the body `{ code, status, message, details }` under grpc-gateway's HTTP status (NOT_FOUND→404, UNAVAILABLE→503, …).
    - The REST decoder then classifies it, so model error matchers on `code` and the retry policy both apply.
  - **Streams:** a server-streaming method (descriptor `[3] = 1`) keeps its collected form: the plain call returns `{ items = { ... } }`, the whole stream from one response.
  - **Incremental streams (task 30):** `protocol.stream(ctx, op, input)` sends through the transport's `stream` entry point and decodes each message as soon as its 5-byte-prefixed frame has arrived (`distilled.stream.grpc`, a port of `FrameReader` pulled one frame at a time). The client method is `client:<op>_stream(input)` (task 29's Stream; ops carry `op.stream = { framing = "grpc", item }`).
    - A non-gRPC reply and a trailers-only reply's non-zero status fail before the first item (`nil, err`), so they can be retried.
    - The status in HTTP trailers (the transport's, once the body ended) or a gRPC-Web trailer frame ends the stream; non-zero gives the operation's typed error from the iterator.
    - A dropped connection ends the stream with the transport's error. A truncated last frame is INTERNAL once the status is OK (the status wins, as in Distilled). A compressed frame is INTERNAL.
    - Each item goes through the output schema as `{ items = { message } }`, as `streamReply` does, so sensitive members are wrapped per item.
- **`distilled.stream.connect`** and **`connect.stream`** (task 30): Connect streaming envelopes (flags byte, 4-byte length, JSON; `0x02` marks end-of-stream with `{ error?, metadata? }`), ported from e2b's `connect.ts`.
  - The request is the REST protocol's (URL, headers, JSON body), the body sent as one envelope with `content-type: application/connect+json`.
  - A non-2xx reply is a unary Connect error body; the end-of-stream `error` ends the stream; both go through a `fail(info)` hook.
  - `connect.stream_method{ op, fail, decode }` makes a client method for an RPC no model declares.
- **e2b envd streams** (task 30): `require("e2b.process")` clients have `start_process_stream` and `connect_process_stream`, `require("e2b.filesystem")` has `watch_dir_stream`. They come from the provider glue (`providers/glue/e2b_envd.lua`, `glue.methods`), which ports `connect.ts`: `decodeProcessEvent`, `decodeWatchDirEvent`, `connectError` and the pre-stream mapping (502 SandboxNotRunning, 5xx without a code InternalServerError, 404 without a code NotFound).
  - Items: `{ _tag = "Start", pid }`, `{ _tag = "Stdout" | "Stderr" | "Pty", data = <bytes> }`, `{ _tag = "End", exitCode, exited, status, error? }`, `{ _tag = "KeepAlive" }`; watch: `{ _tag = "Start" }`, `{ _tag = "Filesystem", name, type, entry? }`, `{ _tag = "KeepAlive" }`.
  - The generator's glue hook `methods = fn(service) -> { [name] = fn(client, input) }` installs them (`gen/writer.lua`, `gen/provider_ext.lua`).
- **Transport** (`transport/curl_common.lua`):
  - `request.http2` becomes `--http2-prior-knowledge` for http:// URLs and `--http2` for https://.
  - HTTP trailers come back in `response.trailers`, with names lowercased. The body is located with curl's `%{size_header}`.
- **`distilled.protocol.connect`** (the `proto` wire `connect`; no generated client uses it now) is `rest.new` with two additions:
  - `empty_json_body` defaults to true;
  - a `prepare` hook derives the settings.
- **`distilled.protocol.rpc`** is the runtime for a provider spec's `proto` section:
  - `prepare` handles environment variables in order, defaults that name other options, `required` and `require_one_of`;
  - `base_url` handles templates, `by_prefix` and `when`/`cases`, and checks host parts;
  - `headers` (rules with `unless`);
  - `envelope`, `unknown_error` and `when_set`.
- **Generator** (`gen/proto.lua`, hooked into `gen/init.lua` and `gen/provider.lua`):
  - It validates the provider spec's `proto` section (`rpc` is task 22's key).
  - It reads Distilled's `src/descriptors.ts`. `dl models sync` copies it to `models/<pkg>/`.
  - It emits `descriptors.lua` with only the messages and enums the client's methods reach.
  - It writes an `init.lua` that wires grpc or connect, extends `README.md` and adds the option fields to `types.lua`.
  - It reads `proto.error_matchers_trait` (`com.modal.protocols#errorMatchers`) as error matchers.
  - gRPC server streams become callable operations.
  - **Generation fails early** when:
    - a method is missing from the descriptors;
    - the streaming flag disagrees between the model and the descriptors;
    - a referenced message is missing;
    - the descriptors file is unreadable;
    - the `proto` spec is bad.

## How a user reaches it

```lua
local Modal = require("modal.app")           -- MODAL_TOKEN_ID / MODAL_TOKEN_SECRET
local app, err = Modal.new({}):app_get_or_create({ appName = "x" })   -- err.tag "AppNotFound"

local Boxd = require("boxd")                 -- BOXD_API_KEY or BOXD_TOKEN
local logs = Boxd.new({}):stream_logs({ vmId = "vm-1" })              -- logs.items
local s = Boxd.new({}):stream_logs_stream({ vmId = "vm-1", follow = true })
for chunk, err in s:iter() do ... end                                  -- each LogChunk

local Process = require("e2b.process")       -- envd: one sandbox
local ps = Process.new({ sandbox_id = id, access_token = tok }):list_processes({})
local run = Process.new({ sandbox_id = id }):start_process_stream({ process = { cmd = "ls" } })
for ev, err in run:iter() do ... end                     -- ev._tag: Start, Stdout, ..., End

local Compute = require("namespacelabs.compute")                      -- NSC_TOKEN, NSC_REGION
local inst = Compute.new({}):create_instance({ ... })   -- https://<region>.compute.namespaceapis.com
```

## Driving it with `dl`

- `verify/dl test protobuf_spec`: differential vectors from Distilled's own `protobuf.ts`.
  - Regenerate them with `node --conditions=bun --experimental-transform-types verify/lib/protobuf_vectors.mjs [count]`.
  - The seed is `DL_PB_SEED`.
  - The vectors cover 212 encode, 218 decode and 11 frame cases, plus hand-written edge cases.
- `verify/dl test grpc_spec` covers:
  - the protocol over a scripted transport (frames, headers, status sources, error mapping, streams, malformed replies, retries);
  - `distilled.protocol.rpc` settings;
  - every generated client: modal, boxd, e2b control plane, envd and volume content, and namespacelabs host routing and errors;
  - `gen.proto` (descriptor parsing, validation, reachable subset, failing early).
  - With `--http`, the same cases also run against `dl serve` through curl.
- `verify/dl test grpc_stream_spec` (frames, statuses, errors, close), `connect_stream_spec` (envelopes, e2b envd streams), `grpc_stream_conform_spec`: 20 cases compared with Distilled's TS (`spec/golden/grpc_stream/conform.json`, regenerated with `node --conditions=bun --experimental-transform-types --no-warnings verify/lib/grpc_stream_conform.mjs spec/golden/grpc_stream/conform.json`).
- `verify/dl gen-diff modal|boxd|e2b|namespacelabs`: a fresh generation matches `clients/`, and the clients load in all three runtimes.
- `verify/dl parity`: modal 304/304, boxd 135/135, e2b 97/97, namespacelabs 182/182.

## Gotchas

- **HTTP/1.1 only through the fixture server.** `dl serve` is HTTP/1.1, so trailers are tested two ways:
  - the HTTP/2 and chunked HTTP/1.1 trailer parsing was checked by hand against a Node `http2` server (see the done file);
  - the spec covers trailers through the scripted transport.
- **Modal over plain HTTP/1.1** works because Modal's envoy bridges it. Only the task command router (`bearer_token`) asks for HTTP/2.
- **Server streams:** the plain call collects (bound a following stream with the request's timeout); `<op>_stream` delivers incrementally and needs a transport with a `stream` entry point (task 29).
  - Client streaming is not ported (e2b `Process.StreamInput` neither: `send_process_input` is unary).
  - A Connect envelope cut short by the end of the body is a ParseError here; `connect.ts` silently drops it.
  - `<op>_stream` names: a stream-only RPC (e2b's) also ends in `_stream`, so every method returning a Stream does.
- **proto3 defaults:** a decoded message has every scalar at its default (`""`, `0`, `false`), as in Distilled. An absent field is not `nil`.
- **Trailing slashes:** `rpc.base_url` trims a trailing `/` from the base URL. Distilled does not, and task 13's REST specs do not either (`${baseUrl}${uri}`).
- **Not ported:**
  - Modal's `fromContainer` (unix socket);
  - the `x-modal-auth-token` fetch (pass `auth_token`);
  - Namespace's token file (`NSC_TOKEN_FILE`).
