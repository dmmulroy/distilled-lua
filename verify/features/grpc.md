# gRPC, gRPC-Web and Connect (`distilled.protobuf`, `distilled.protocol.grpc`, `distilled.protocol.connect`)

Task 23 adds proto-sourced providers: modal and boxd over the binary gRPC wire (and gRPC-Web), and e2b
over Connect JSON. namespacelabs (Connect JSON too) uses task 13's REST provider spec and glue
(`providers/namespacelabs.lua`, merged from main); task 23 generated and tested its clients.

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
  - **Streams:** a server-streaming method (descriptor `[3] = 1`) returns `{ items = { ... } }`, the whole stream collected from one response.
- **Transport** (`transport/curl_common.lua`):
  - `request.http2` becomes `--http2-prior-knowledge` for http:// URLs and `--http2` for https://.
  - HTTP trailers come back in `response.trailers`, with names lowercased. The body is located with curl's `%{size_header}`.
- **`distilled.protocol.connect`** (used by e2b) is `rest.new` with two additions:
  - `empty_json_body` defaults to true;
  - a `prepare` hook derives the settings.
- **`distilled.protocol.rpc`** is the runtime for a provider spec's `rpc` section:
  - `prepare` handles environment variables in order, defaults that name other options, `required` and `require_one_of`;
  - `base_url` handles templates, `by_prefix` and `when`/`cases`, and checks host parts;
  - `headers` (rules with `unless`);
  - `envelope`, `unknown_error` and `when_set`.
- **Generator** (`gen/proto.lua`, hooked into `gen/init.lua` and `gen/provider.lua`):
  - It validates the provider spec's `rpc` section.
  - It reads Distilled's `src/descriptors.ts`. `dl models sync` copies it to `models/<pkg>/`.
  - It emits `descriptors.lua` with only the messages and enums the client's methods reach.
  - It writes an `init.lua` that wires grpc or connect, extends `README.md` and adds the option fields to `types.lua`.
  - It reads `rpc.error_matchers_trait` (`com.modal.protocols#errorMatchers`) as error matchers.
  - gRPC server streams become callable operations.
  - **Generation fails early** when:
    - a method is missing from the descriptors;
    - the streaming flag disagrees between the model and the descriptors;
    - a referenced message is missing;
    - the descriptors file is unreadable;
    - the `rpc` spec is bad.

## How a user reaches it

```lua
local Modal = require("modal.app")           -- MODAL_TOKEN_ID / MODAL_TOKEN_SECRET
local app, err = Modal.new({}):app_get_or_create({ appName = "x" })   -- err.tag "AppNotFound"

local Boxd = require("boxd")                 -- BOXD_API_KEY or BOXD_TOKEN
local logs = Boxd.new({}):stream_logs({ vmId = "vm-1" })              -- logs.items

local Process = require("e2b.process")       -- envd: one sandbox
local ps = Process.new({ sandbox_id = id, access_token = tok }):list_processes({})

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
  - `rpc` settings;
  - every generated client: modal, boxd, e2b control plane, envd and volume content, and namespacelabs host routing and errors;
  - `gen.proto` (descriptor parsing, validation, reachable subset, failing early).
  - With `--http`, the same cases also run against `dl serve` through curl.
- `verify/dl gen-diff modal|boxd|e2b|namespacelabs`: a fresh generation matches `clients/`, and the clients load in all three runtimes.
- `verify/dl parity`: modal 304/304, boxd 135/135, e2b 97/97, namespacelabs 182/182.

## Gotchas

- **HTTP/1.1 only through the fixture server.** `dl serve` is HTTP/1.1, so trailers are tested two ways:
  - the HTTP/2 and chunked HTTP/1.1 trailer parsing was checked by hand against a Node `http2` server (see the done file);
  - the spec covers trailers through the scripted transport.
- **Modal over plain HTTP/1.1** works because Modal's envoy bridges it. Only the task command router (`bearer_token`) asks for HTTP/2.
- **Server streams are collected, not incremental.** Bound a following stream with the request's timeout.
  - Client streaming and the Connect server streams (e2b `connect.ts`) are not ported.
- **proto3 defaults:** a decoded message has every scalar at its default (`""`, `0`, `false`), as in Distilled. An absent field is not `nil`.
- **Trailing slashes:** `rpc.base_url` trims a trailing `/` from the base URL. Distilled does not, and task 13's REST specs do not either (`${baseUrl}${uri}`).
- **Not ported:**
  - Modal's `fromContainer` (unix socket);
  - the `x-modal-auth-token` fetch (pass `auth_token`);
  - Namespace's token file (`NSC_TOKEN_FILE`).
