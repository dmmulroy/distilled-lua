# Task 12: traits the generator refuses (per-operation hosts, accept, streaming, pagination edge cases)

Read `tasks/10-parity-overview.md` first. Failing models: `tasks/notes/smoke-results.txt`;
reproduce with `sh tasks/notes/smoke-run1.sh <pkg>/<model>`.

## Files you own

```text
lua/distilled/gen/traits.lua, gen/ops.lua (except rawResponse output handling: task 11),
gen/errors.lua, gen/model.lua
lua/distilled/request.lua, url.lua       ONLY per-operation base URL / accept
lua/distilled/protocol/rest.lua          ONLY per-operation base URL / accept plumbing
lua/distilled/gen/provider.lua           ONLY the UNSUPPORTED table
spec/gen_*_spec.lua (new cases), spec/request_spec.lua (new cases), fixtures
STATUS.md (section "12 traits")
```

## Requirements

1. `smithy.api#http` extra keys: `baseUrl` (scaleway, stackit), `server` (digitalocean),
   `accept` (mongodb-atlas). Find how Distilled's generator and `protocol-http.ts` /
   `protocol-rest.ts` use each (per-operation base URL override; Accept header) and port it:
   generator emits it into the op, `request.build` / the REST protocol honour it.
   Template variables in a base URL (e.g. `{region}`) come from client options; read
   `../distilled/packages/scaleway/src/protocol.ts` and `stackit/src/protocol.ts` to see
   how they are filled, and leave a clean hook for the provider spec (task 13 owns
   provider-spec keys; describe what you need in STATUS.md).
2. Streaming (`com.distilled.grpc#serverStreaming`, `#clientStreaming`,
   `com.distilled.openapi#streamWhen`, anything else under those namespaces): add
   `"streaming"` to `provider.UNSUPPORTED` so a provider spec can emit those operations
   that fail with `SdkError` at call time. Also make sure a whole gRPC model (modal, boxd)
   then generates (it will not be callable until a gRPC protocol exists; note it).
3. Pagination: exa's `ListWebsets` `_items` method collides with operation
   `ListWebsetsItems` (check what Distilled names them; pick a deterministic rule).
   resend's cursor pagination without `outputToken`: check what Distilled does with that
   trait (it may be a link/next-url style); support it or emit the op unpaginated with
   a warning, mirroring Distilled.
4. `distilled.errors#bodies` whose target is a prelude shape (`smithy.api#String`,
   `smithy.api#Double`) (coinflow).
5. A path label with no input member (proxmox `{url_seq}`): what does Distilled do?
   Mirror it.
6. Rerun the smoke script on every model of these classes and report before/after.
   `verify/dl gen-diff neon` byte-identical, conformance replay green.
