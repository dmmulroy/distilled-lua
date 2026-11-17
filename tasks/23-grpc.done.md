# Task 23 (grpc): done

Branch `task-23`. Main is merged in, up to `07674aa` (tasks 13, 16, 18, 22 and 26).

## What was built

- **`lua/distilled/protobuf.lua`** is a proto3 binary codec over Distilled's descriptor tables. It ports `core/src/protobuf.ts`.
  - **Wire types:** varints, with 64-bit values as decimal strings like Distilled's proto3 JSON and held internally as two float halves. Also zigzag, fixed32/64, and doubles and floats via pure-Lua IEEE-754 packing (no `string.pack`).
  - **Message structure:** length-delimited fields, packed and unpacked repeated fields, maps, oneof and `optional` presence, enums as names (numbers when unknown), nested messages, and skipped unknown fields.
  - **Well-known types:** Timestamp, Duration, Struct, Value, ListValue, FieldMask, Any, the wrappers and Empty.
  - **Framing:** `frame` and `unframe` handle gRPC message frames and gRPC-Web trailer frames.
  - **Failures** return `nil, err` as InvalidInput or ParseError, with `protobuf = "Protobuf*Error"`.
  - **Nesting:** an explicit depth bound, `MAX_DEPTH = 100`, because of gopher-lua's call stack.
  - **Deliberate differences** are listed in the module header: key order, U+FFFD and base64 errors.
- **`lua/distilled/protocol/grpc.lua`** handles unary gRPC and gRPC-Web, built on the REST protocol. It ports `protocol-grpc.ts`.
  - **Request:** one frame.
    - gRPC: `application/grpc` and `te: trailers`.
    - gRPC-Web (`web = true`): `application/grpc-web+proto` and `x-grpc-web: 1`.
  - **Status sources, in order:** HTTP trailers, then a gRPC-Web trailer frame, then headers (a trailers-only reply).
    - A reply with message frames and no status is OK.
    - Trailers without a status are INTERNAL.
    - An empty reply without a status is UNKNOWN.
  - **`grpc-message`** is percent-decoded when valid.
  - **`grpc-status-details-bin`** is decoded as `google.rpc.Status` details.
  - **Errors:** a non-zero code becomes the body `{ code, status, message, details }` under grpc-gateway's HTTP status. The REST decoder classifies it, so model matchers on the numeric `code` and the retry policy apply as in Distilled.
  - **Server streaming is supported, not left unsupported:** a method marked streaming in its descriptor returns `{ items }`, the whole stream collected from one HTTP response. Client streaming and incremental streams are not.
- **`lua/distilled/protocol/connect.lua`** is Connect JSON unary for e2b: `rest.new` with `empty_json_body` defaulting to true, plus a `prepare` hook.
- **`lua/distilled/protocol/rpc.lua`** is the runtime for the provider spec's `proto` section:
  - `prepare`: environment lists in order, defaults that name other options, `required` and `require_one_of`;
  - `base_url`: templates, `by_prefix` and `when`/`cases`, with host parts checked;
  - `headers` (rules with `unless`);
  - `envelope`, `unknown_error` and `when_set`.
- **`lua/distilled/gen/proto.lua`**, with hooks in `gen/init.lua` and `gen/provider.lua`:
  - It validates the provider spec key `proto` (documented in its header). The key was renamed from `rpc` at the task-22 merge, because task 22 owns `rpc`.
  - It reads `src/descriptors.ts`. `dl models sync` now copies it to `models/<pkg>/`.
  - It emits `descriptors.lua` with only the messages and enums the client's methods reach.
  - It writes `init.lua` wiring grpc or connect, and extends `README.md` and `types.lua`.
  - It reads `proto.error_matchers_trait` (`com.modal.protocols#errorMatchers`) as error matchers.
  - It makes gRPC server-streaming ops callable.
  - It **fails at generation** on:
    - a method missing from the descriptors;
    - a streaming flag that disagrees between model and descriptors;
    - a message or enum missing from the descriptors;
    - an unreadable descriptors file;
    - a bad `proto` spec;
    - `proto` together with `rpc`, `status_map`, `classify_error` or `protocol`.
- **Transport** (`transport/curl_common.lua`):
  - `request.http2` must be a boolean. It becomes `http2-prior-knowledge` for http:// and `http2` for https://.
  - HTTP trailers come back in `response.trailers` (lowercase names), found with `%{size_header}`.
  - **Race fix:** `data-binary` is now the last config line. curl reads the `@/dev/fd/3` body file when it parses that line, and fd 3 shares its offset with the stdin `dd` copies the config from. So any later config line could be taken as body. See STATUS 23.
- **Providers and generated clients:**
  - `providers/modal.lua` gives `clients/modal/`: 40 models, 304 ops, binary gRPC.
    - Headers: the token id and secret, `x-modal-auth-token`, and a bearer instead of the token pair over HTTP/2 for the task command router.
    - Client type 8, `x-modal-client-version: 1.6.3` and `x-modal-libmodal-version`.
  - `providers/boxd.lua` gives `clients/boxd/`: 135 ops, gRPC-Web, bearer from `BOXD_API_KEY` then `BOXD_TOKEN`, with 4 server-streaming ops callable.
  - `providers/e2b.lua` gives `clients/e2b/`: 16 models, 97 ops, Connect and REST JSON.
    - Control plane: `X-API-Key`, bearer and `X-Team-ID`, with one of the key and the token required.
    - envd: the shared `sandbox.<domain>` host or `<port>-<id>.<domain>`, routing headers, `X-Access-Token` and `{}` bodies.
    - Volume content: the volume token as the bearer.
    - SandboxNotRunning on 502.
  - `clients/namespacelabs/`: 29 models, 182 ops.
    - Generated from main's `providers/namespacelabs.lua`, which is task 13's REST spec plus glue (host by proto package, `{}` bodies, `details` on the unknown error).
    - My `proto` version was dropped at the merge because task 13's keys cover it.
  - `verify/dl parity`: modal 304/304, boxd 135/135, e2b 97/97, namespacelabs 182/182.
- **Specs:**
  - `spec/protobuf_spec.lua`: 15 tests, including differential vectors from Distilled's own `protobuf.ts` through Node (`verify/lib/protobuf_vectors.mjs` gives `spec/golden/protobuf/vectors.json`: 212 encode, 218 decode and 11 frame cases).
  - `spec/grpc_spec.lua`: 55 tests with `--http`. It covers the protocol, the fixture-server cases, the rpc runtime, every generated client, `gen.proto` and the curl config.
  - `verify/features/grpc.md` is the feature doc.

## Commands run and their output (final tree, after merging main at 07674aa)

```text
$ verify/dl doctor
doctor: ok

$ verify/dl test --http
  lua: ok 1707 passed [Lua 5.5]
  luajit: ok 1707 passed [luajit]
  rex: ok 1674 passed, 5 pending [rex]
(and, on the tree before the task-26 merge: 2 more full --http runs, 1703/1703/1670 each,
 plus verify/dl test without --http: 1657 + 6 pending / 1657 + 6 pending / 1644 + 11 pending)

$ verify/dl test --http grpc
  lua: ok 55 passed [Lua 5.5]
  luajit: ok 55 passed [luajit]
  rex: ok 55 passed [rex]

$ verify/dl test protobuf
  lua: ok 15 passed [Lua 5.5]
  luajit: ok 15 passed [luajit]
  rex: ok 15 passed [rex]
(during development the vectors also ran at 3000 cases with DL_PB_SEED=5,6,7,8,99,1234)

$ verify/dl gen-diff boxd | modal | e2b | namespacelabs     (also tencentcloud, neon: ok)
gen-diff boxd: ok           (gen-check lua/luajit/rex: 135/135 ops built, client loads)
gen-diff modal: ok          (304/304)
gen-diff e2b: ok            (97/97)
gen-diff namespacelabs: ok  (182/182)

$ verify/dl parity   (the four rows; verify/features/parity.md not committed, see below)
boxd                  135      135        1/1        0  yes
e2b                    97       97      16/16        0  yes
modal                 304      304      40/40        0  yes
namespacelabs         182      182      29/29        0  yes
```

**HTTP/2 trailers, checked by hand** (popen_curl against a Node server, `/tmp/t23/srv.mjs`):
- `http2.createServer` with `respond({ ':status': 200 }, { waitForTrailers: true })` gave `res.trailers = { ["grpc-message"] = "not%20found", ["grpc-status"] = "5" }`.
- A chunked HTTP/1.1 reply with `addTrailers` gave `grpc-status = "7"`.

**The exec_curl race, reproduced and diagnosed:**
- Before the fix, `transport_spec` "sends headers exactly" failed in about one full `--http` run in three.
- With the error message instrumented, curl's stdout ended in an unexpanded, cut write-out (`... 200 599 %{size_he`). The echo server had received an 8-byte body instead of `x`: the config tail plus the body.
- After the fix: 6 consecutive full `--http` runs were clean.

## Skipped, and why

- **Live API calls:** none, by rule. Every client is tested against scripted transports and the fixture server.
- **HTTP/2 through the fixture server:** `dl serve` is HTTP/1.1 (Python's `http.server`; there is no `h2` module here). HTTP/2 trailer parsing was checked by hand against Node, as shown above. The spec covers `http2` config and trailers through a scripted transport.
- **Not ported from Distilled:**
  - incremental streams (`.stream`);
  - client streaming;
  - e2b's hand-written Connect server streams (`src/connect.ts`);
  - Modal's `fromContainer` (unix socket), which is outside the transport contract;
  - the `x-modal-auth-token` fetch and cache (pass `auth_token`);
  - Namespace's `CredentialsFromTokenFile`;
  - Distilled's own HTTP/2 client (`grpc-transport*.ts`, `hpack.ts`): curl's `--http2` replaces it.

## Open problems (also in STATUS 23)

- **Edits outside my brief:**
  - `spec/provider_spec.lua` `NAMES`: added `"boxd"` and `"modal"`. The merge broke it otherwise.
  - `gen/init.lua` and `gen/provider.lua`: hooks only, guarded by `spec.proto`.
  - `verify/dl models sync`: copies `descriptors.ts`.
- **Proposed contract additions (`docs/interfaces.md`):**
  - `request.http2?: boolean`;
  - `response.trailers?: { [lowercase name] = value }`;
  - `distilled.testing`'s transport should pass `trailers` through. `spec/grpc_spec.lua` uses its own scripted transport because it currently drops them.
- **`gen/traits.lua`'s note for `com.distilled.grpc#serverStreaming`** should say that the ops are callable on the proto grpc wires.
- **Overlap with task 13:** `proto.options`, `proto.headers` and `proto.base_url` duplicate task 13's top-level keys. Proposed: let `models.override` carry `options` and `headers`, so `proto` keeps only `wire`, `descriptors`, `http2` and `error_matchers_trait`, and e2b moves to task 13's keys.
- **Trailing slashes:** `rpc.base_url` trims a trailing `/`. Distilled and task 13 do not.
- **Stale committed files on main:**
  - `verify/features/parity.md`: rerun `verify/dl parity`. I did not commit it because I do not own it.
  - `clients/hetzner`: it differs from a fresh generation on main's own tree, so `dl gen-diff hetzner` fails. Task-23 gives byte-identical output, so it is not from this task.

## Later merges (orchestrator request)

- **Merged main again** (tasks 17 and 27). In `gen/init.lua`, the proto hooks now sit beside the aws ones:
  - `aws.event_stream`, then `proto.streaming`;
  - the aws `init.lua` and README, then the proto override.
- **e2b:** task 27 rewrote `providers/e2b.lua` with extended per-model overrides, as STATUS 23 proposed. I took its spec and `clients/e2b`, and the e2b cases in `spec/grpc_spec.lua` pass against it.
- **`protocol/connect.lua`** is no longer used by a generated client. It remains the `proto` `connect` wire.
