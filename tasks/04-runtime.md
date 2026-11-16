# Task 04: policies, protocol, operation, client

You build layers 3 to 6: retry, pagination, credentials, the REST protocol, the operation
executor and the client. When you finish, a hand-written service descriptor can be called
end to end over the scripted transport, with tracing.

Tasks 01 (harness, json, errors, secret, scope), 02 (tracing) and 03 (schema, request, keys,
redact, validate, regex, testing seams) are finished. Read their done files in `tasks/` and
`STATUS.md` first: they record where the code deviates from `docs/interfaces.md`.

Read `AGENTS.md`, then `../distilled-lua-plan.md` in full, then `docs/interfaces.md`
("Policies", "Protocol, operation, client"), then sections 4.1, 4.4, 4.6, 4.7 and 4.10 of
`../distilled-deep-dive.md`.

Reference implementation in `../distilled/packages/core/src/`: `api.ts` (`applyRetry`,
`retryWith`, `backoffDelay`, `callOperation`), `retry.ts`, `retry-after.ts`,
`retry-state.ts`, `pagination.ts`, `protocol-rest.ts` (`makeRestProtocol`, `decodeText`,
`decodeSuccess`, `checkSuccess`), `send.ts`. Port the cases in
`../distilled/packages/core/test/retry.test.ts`, `retry-after.test.ts`,
`pagination.test.ts`, `protocol-rest.test.ts`.

Two things to know before you start:

- gopher-lua corrupts closure upvalues when a protected call catches an error in certain
  nestings. `compat.pcall` is the only safe way to catch a raise (it is coroutine-based
  after task 02's follow-up). Never write `pcall` or `xpcall` yourself. Your code should
  rarely need to catch anything: failures are `nil, err`. The places that must catch are
  user callbacks (credential functions, `classify_error`, `error_envelope`, retry `when`):
  wrap those with `compat.pcall` and turn a raise into an `SdkError`.
- With tracing off, hold `require("distilled.trace.noop")` and never require
  `distilled.trace`. Set `err.trace_id` yourself in the operation layer.

## Files you own

```text
lua/distilled/retry.lua        policy data, backoff, budget, Retry-After / RateLimit parsing, run loop
lua/distilled/paginate.lua     the seven modes, iterator object
lua/distilled/credentials.lua  resolve, from_env, from_file, from_command, cache + refresh-on-401
lua/distilled/protocol/rest.lua
lua/distilled/operation.lua    call one op: tracing span, retry, protocol
lua/distilled/client.lua       Client.define, new, with, close; method dispatch
lua/distilled/host.lua         default host table and merging of user-supplied fields
lua/distilled/init.lua         add public exports only (do not change existing ones)
spec/{retry,paginate,credentials,rest,operation,client}_spec.lua   spec/golden/trace/*
verify/features/{retry,pagination,credentials,rest-protocol,client}.md
examples/fake_service.lua      a runnable script for `dl trace` over the scripted transport
STATUS.md (your section)
```

## Requirements

1. **Retry** (`retry.lua`)
   - Policy is data: `{ when = fn(err), max_retries, base_ms, throttling_base_ms, factor,
     cap_ms, full_jitter, jitter_ms, min_throttle_ms, server_hint, budget, long_poll }` with
     the same numbers as Distilled for `DEFAULT`, `THROTTLING`, `TRANSIENT`, `NONE`. An
     operation's `op.retry` overrides the default's numbers when the client set no policy.
   - The call runs once with no retry bookkeeping; the policy is consulted only after a failure.
   - Server hints: `err.retry_after` is a minimum wait; a hint over the cap (default 60 s,
     option `server_hint_cap_s`) stops retrying. Bounded hints (`x-amz-retry-after`,
     `x-distilled-retry-after`, milliseconds) clamp to `[t, t + 5s]`.
   - Budget: per-host token bucket with Distilled's numbers, shared by a client and every
     client derived from it with `with`. A module-level default budget is shared by clients
     that do not pass one.
   - **Deadline:** `deadline_s` is the wall-clock budget for the whole call including
     sleeps. Before sleeping, if `now + delay` would pass the deadline, return the last
     error instead of sleeping. Pass the remaining time to the transport as `request.timeout`.
   - All waiting goes through `host.sleep`; all randomness through `host.random`.
   - Tracing: each attempt and each backoff is a debug span; the operation span gets
     `distilled.retry.attempts` and `distilled.retry.delay_ms` (match the attribute names in
     `telemetry.ts`).
2. **Pagination** (`paginate.lua`): `token`, `cursor`, `page`, `relay`, `link`, `keyset`,
   `single`, each with every stop condition in `pagination.ts` (they exist because real APIs
   looped forever). The iterator object is callable for `for`, stops at the first failure
   and records it in `it.err`, has `it:collect([limit])` returning `list` or `nil, err`, and
   `it:close()`. `limit` stops fetching pages once enough items are collected. `link` mode
   needs the response headers of the page call: design how the protocol hands them to the
   paginator without a global (for example a second return value from the page call), and
   write it in `STATUS.md`.
3. **Credentials** (`credentials.lua`): a source is a string, a secret, or
   `fn(host) -> value | nil, err`. Resolved on first use and cached on the client; when a
   call fails with `Unauthorized`, the cache is cleared, the source resolved once more, and
   the call retried a single time (only when the source is a function). `from_file` trims
   trailing whitespace. `from_command(argv)` uses `host.exec` and fails with `ConfigError`
   when the host has none. Resolved values are always held as secrets.
4. **REST protocol** (`protocol/rest.lua`), following `makeRestProtocol`:
   - Request: credentials, base URL, auth headers, `request.build`, then `traceparent` when
     the tracer is recording, `accept: application/json`, a `user-agent`.
   - Failure classification in Distilled's order: `classify_error`; the operation's declared
     errors by matcher; the status map; unmapped 5xx as retryable `InternalServerError`; the
     provider's unknown error (never retryable). `retry_after` is set only on retryable statuses.
   - Success: tolerant JSON parse; `keys.decode`; response header members; validation when
     the mode is not lenient (failures are the provider's parse error); `redact.wrap`. A
     non-JSON body for an output that can hold a secret fails in every mode, and parse
     errors for such outputs carry `"[REDACTED]"` instead of the body.
   - A failed call's error gets `trace_id` when tracing is on.
5. **Operation and client**
   - `Client.define{ service, protocol, options }` returns a class. `Class.new(opts)`
     validates options (unknown option names are misuse: raise with a message that lists
     the valid names). Methods are resolved through the metatable from `service.ops`:
     `client:get_project(input)`; for paginated operations also `client:list_x_pages(input)`
     and `client:list_x_items(input)`. Calling with `.` instead of `:` must fail with a
     clear misuse message, not a confusing nil index.
   - `client:with{ ... }` returns a derived client that shares the budget, the credentials
     cache and the tracer unless overridden. `tracing` accepts `"off" | "operation" |
     "debug"` or `{ level, file, max_bytes, exporter }`; the trace module is `require`d only
     when tracing is not off.
   - Spans are flushed when the outermost operation call on that tracer returns (so a Rex
     action never returns with unexported spans), and on `client:close()`.
   - One operation span per call, kind client, named and attributed from `op.span` and
     `service.telemetry` as `telemetry.ts` does (`rpc.system.name`, `rpc.method`,
     `url.template`, `http.request.method`, `server.address`, `http.response.status_code`,
     `error.type`). A paginated traversal has one parent span with a child per page.
   - Input is never mutated.
6. **Specs** use `testing.host` and `testing.transport` from task 03 and `expect` from task
   02, and assert on traces for the retry and pagination behaviour (attempt counts, backoff
   delays with the seeded random, deadline cut-off, budget exhaustion, refresh-on-401,
   each pagination stop condition).
7. **`examples/fake_service.lua`**: a script that builds the fixture service, calls a few
   operations including a retried one, a paginated one and a failing one, and returns the
   results, so `verify/dl trace examples/fake_service.lua --level debug` prints a full tree
   under each runtime.

## Done means

- `verify/dl doctor` clean, `verify/dl test` green in all three runtimes.
- `tasks/04-runtime.done.md` committed with the command output, the three `dl trace` trees,
  the list of Distilled test cases ported, and anything skipped.
