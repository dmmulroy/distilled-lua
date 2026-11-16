# Task 04 runtime: done

## What was built

- `lua/distilled/retry.lua`: Distilled's policies (`DEFAULT`, `THROTTLING`, `TRANSIENT`,
  `NONE`), `policy_for` (an `op.retry` override applies only when the client set no
  policy), backoff (full jitter / fixed + jitter / throttle floor), server hints
  (Retry-After seconds and the 3 HTTP-date forms, RateLimit, bounded `x-amz-retry-after` /
  `x-distilled-retry-after` clamped to `[t, t+5s]`, a 60 s cap that stops retrying when a
  hint is over it), a per-host token budget (100/500/14/5, refund on retry success, shared
  default), `deadline_s` cut-off with `request.timeout` set to the time left, and `run`,
  which records `distilled.attempts`, `distilled.retry.errors`, `distilled.retry.delay_ms`
  and `distilled.retry.stopped` plus debug `distilled.attempt` / `distilled.retry.backoff`
  spans.
- `lua/distilled/paginate.lua`: the token, cursor, page, relay, link, keyset and single
  modes, with every stop condition from `pagination.ts` (recorded in `it.stop`). The
  iterator is callable and has `it.err`, `:collect([limit])`, `:close()` and a
  `distilled.pagination` traversal span. Link headers come through the third return value
  `meta.headers` (no global).
- `lua/distilled/credentials.lua`: sources (a string, a secret, or `fn(host)`),
  `from_env`, `from_file` (trailing whitespace trimmed), `from_command` (via `host.exec`,
  else `ConfigError`), cache cells, and refreshing function sources.
- `lua/distilled/protocol/rest.lua`: request (credentials, base_url, auth headers,
  `request.build`, traceparent, accept, user-agent, timeout). Failures are classified in
  Distilled's order. Success covers header and status members, payload, raw/binary
  outputs, 204 and empty bodies, tolerant parsing, validation modes, the parse error, and
  redaction (a non-JSON body for a secret-holding output always fails, and the error shows
  `[REDACTED]`). There are debug spans for credentials, build, transport and decode.
- `lua/distilled/operation.lua`: `operation.info` (port of `telemetry.ts operationInfo`,
  label rules and transforms), one client span per call, `err.trace_id`, flush when the
  outermost call returns (also after a raise), and refresh-on-401 (retried once).
- `lua/distilled/client.lua`: `Client.define` / `new` / `with` / `close` / `is`. Option
  checking raises with the list of valid names, and calling with `.` instead of `:` gives
  a misuse error. `tracing` accepts `off|operation|debug|{level,file,max_bytes,exporter}`,
  plus `tracer` and `trace_parent`/`TRACEPARENT`. A derived client shares the budget,
  credentials and tracer. With tracing off, `distilled.trace` is never loaded.
- `lua/distilled/host.lua`: `merge`/`default` with defaults for sleep, clock, random and
  getenv.
- `lua/distilled/init.lua`: exports `Client`, `rest`, `retry`, `paginate`, `credentials`
  and `host`.
- Inherited fixes:
  - `secret.unwrap_deep` keeps `json.null` (the failing spec came first), and
    `request.build` now uses it.
  - Header members are decoded.
  - 204, empty, raw and binary bodies, parse errors and typed errors are handled through
    whole calls.
  - The `verify/features/README.md` index now lists the 03 and 04 areas, and the stale
    `matches` note is removed from `errors.md`.
- Specs:
  - `spec/{retry,paginate,credentials,rest,operation,client}_spec.lua`.
  - Goldens `spec/golden/trace/runtime_{get_project_retry,list_projects_items,get_project_not_found}.txt`
    (regenerate with `DL_GOLDEN_WRITE=1 lua spec/run.lua client_spec`).
- `examples/fake_service.lua`: a retried, a paginated and a failing call. It returns an
  `expect` check for `dl expect`.
- `verify/features/{retry,pagination,credentials,rest-protocol,client}.md`.

## Commands and output

```
$ verify/dl doctor
ok   lua: Lua 5.5.1 ...
ok   luajit: LuaJIT 2.1.1794386141 ...
ok   rex: "Lua 5.1"
ok   curl / stylua / node
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test          (whole tree, including other agents' specs at that moment)
  lua: ok 952 passed, 3 pending [Lua 5.5]
  luajit: ok 971 passed, 3 pending [luajit]
  rex: ok 970 passed, 6 pending [rex]

$ for s in <my specs>; lua/luajit spec/run.lua $s; rex do spec/run.lua filter=$s
retry_spec:       ok 87 passed  (lua, luajit, rex)
paginate_spec:    ok 63 passed  (lua, luajit, rex)
credentials_spec: ok 23 passed  (lua, luajit, rex)
rest_spec:        ok 78 passed  (lua, luajit, rex)
operation_spec:   ok 20 passed  (lua, luajit, rex)
client_spec:      ok 43 passed  (lua, luajit, rex)
secret_spec:      ok 15 passed; request_spec: ok 61 passed; init_spec: ok 6 passed (all three)

$ verify/dl expect examples/fake_service.lua [--level operation] --runtime lua|luajit|rex
expect: ok      (all 6 combinations)
```

The pending tests are not mine (the client and credentials specs only go pending when
`verify/tmp` is not writable). Mutation check on retry: 11 retry_spec tests failed against
mutated backoff, budget and hint code.

## Traces: `verify/dl trace examples/fake_service.lua --level debug --runtime R`

All three runtimes produce the same 37-span tree (45 lines). The only differences are the
jittered second backoff (lua 61 ms, luajit 68 ms, rex 20 ms), because the `dl` host's
random is not seeded per run. Lines are cut at 170 characters.

### rex
```
trace 2f586c11b7c2609bf9f7958f808f5eb6
  Neon.GetProject client 1021.9ms unset distilled.attempts=3 distilled.retry.delay_ms=1020 distilled.retry.errors=[TooManyRequests,ServiceUnavailable] http.request.method
    distilled.attempt 0.3ms ERROR "slow down" distilled.attempt=1 error.type=TooManyRequests http.request.resend_count=0 http.response.status_code=429
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=429 server.address=console.neon.tech
      distilled.decode 0.1ms ERROR "slow down" error.type=TooManyRequests
    distilled.retry.backoff 1000.0ms unset distilled.retry.attempt=1 distilled.retry.delay_ms=1000 distilled.retry.reason=TooManyRequests
    distilled.attempt 0.4ms ERROR "try again" distilled.attempt=2 error.type=ServiceUnavailable http.request.resend_count=1 http.response.status_code=503
      distilled.credentials 0.0ms unset
      distilled.request.build 0.1ms unset
      distilled.transport 0.1ms unset http.request.method=GET http.response.status_code=503 server.address=console.neon.tech
      distilled.decode 0.1ms ERROR "try again" error.type=ServiceUnavailable
    distilled.retry.backoff 20.2ms unset distilled.retry.attempt=2 distilled.retry.delay_ms=20 distilled.retry.reason=ServiceUnavailable
    distilled.attempt 0.7ms unset distilled.attempt=3 http.request.resend_count=2 http.response.status_code=200
      distilled.credentials 0.0ms unset
      distilled.request.build 0.1ms unset
      distilled.transport 0.1ms unset http.request.method=GET http.response.status_code=200 server.address=console.neon.tech
      distilled.decode 0.1ms unset
trace 1354569280a27b57c607a895b9e179bc
  distilled.pagination 2.4ms unset distilled.pagination.items=3 distilled.pagination.kind=items distilled.pagination.mode=cursor distilled.pagination.operation=Neon.ListP
    Neon.ListProjects client 0.5ms unset http.request.method=GET http.response.status_code=200 rpc.method=Neon/ListProjects rpc.system.name=neon-api server.address=consol
      distilled.attempt 0.5ms unset distilled.attempt=1 http.request.resend_count=0 http.response.status_code=200
        distilled.credentials 0.0ms unset
        distilled.request.build 0.1ms unset
        distilled.transport 0.1ms unset http.request.method=GET http.response.status_code=200 server.address=console.neon.tech
        distilled.decode 0.2ms unset
    Neon.ListProjects client 0.3ms unset http.request.method=GET http.response.status_code=200 rpc.method=Neon/ListProjects rpc.system.name=neon-api server.address=consol
      distilled.attempt 0.3ms unset distilled.attempt=1 http.request.resend_count=0 http.response.status_code=200
        distilled.credentials 0.0ms unset
        distilled.request.build 0.1ms unset
        distilled.transport 0.1ms unset http.request.method=GET http.response.status_code=200 server.address=console.neon.tech
        distilled.decode 0.1ms unset
trace 812882ec0742ebc522b355a799d012a3
  Neon.GetProject client 0.3ms ERROR "project not found" error.type=NotFound http.request.method=GET http.response.status_code=404 neon.project_id=proj-missing rpc.method
    distilled.attempt 0.2ms ERROR "project not found" distilled.attempt=1 error.type=NotFound http.request.resend_count=0 http.response.status_code=404
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=404 server.address=console.neon.tech
      distilled.decode 0.1ms ERROR "project not found" error.type=NotFound
```

### lua
```
trace 85f9fb1fd2d24a9514d447228a948277
  Neon.GetProject client 1061.6ms unset distilled.attempts=3 distilled.retry.delay_ms=1061 distilled.retry.errors=[TooManyRequests,ServiceUnavailable] http.request.method
    distilled.attempt 0.1ms ERROR "slow down" distilled.attempt=1 error.type=TooManyRequests http.request.resend_count=0 http.response.status_code=429
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=429 server.address=console.neon.tech
      distilled.decode 0.0ms ERROR "slow down" error.type=TooManyRequests
    distilled.retry.backoff 1000.0ms unset distilled.retry.attempt=1 distilled.retry.delay_ms=1000 distilled.retry.reason=TooManyRequests
    distilled.attempt 0.1ms ERROR "try again" distilled.attempt=2 error.type=ServiceUnavailable http.request.resend_count=1 http.response.status_code=503
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=503 server.address=console.neon.tech
      distilled.decode 0.0ms ERROR "try again" error.type=ServiceUnavailable
    distilled.retry.backoff 61.3ms unset distilled.retry.attempt=2 distilled.retry.delay_ms=61 distilled.retry.reason=ServiceUnavailable
    distilled.attempt 0.1ms unset distilled.attempt=3 http.request.resend_count=2 http.response.status_code=200
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=200 server.address=console.neon.tech
      distilled.decode 0.0ms unset
trace a99f9a106aa31dc6474c119fb439eb7e
  distilled.pagination 0.6ms unset distilled.pagination.items=3 distilled.pagination.kind=items distilled.pagination.mode=cursor distilled.pagination.operation=Neon.ListP
    Neon.ListProjects client 0.1ms unset http.request.method=GET http.response.status_code=200 rpc.method=Neon/ListProjects rpc.system.name=neon-api server.address=consol
  ... (pagination and not-found traces identical to rex)
```

### luajit
```
trace 6b16474f2edc4a77ee6720dac6c100d3
  Neon.GetProject client 1068.2ms unset distilled.attempts=3 distilled.retry.delay_ms=1068 distilled.retry.errors=[TooManyRequests,ServiceUnavailable] http.request.method
    distilled.attempt 0.1ms ERROR "slow down" distilled.attempt=1 error.type=TooManyRequests http.request.resend_count=0 http.response.status_code=429
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=429 server.address=console.neon.tech
      distilled.decode 0.0ms ERROR "slow down" error.type=TooManyRequests
    distilled.retry.backoff 1000.0ms unset distilled.retry.attempt=1 distilled.retry.delay_ms=1000 distilled.retry.reason=TooManyRequests
    distilled.attempt 0.1ms ERROR "try again" distilled.attempt=2 error.type=ServiceUnavailable http.request.resend_count=1 http.response.status_code=503
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=503 server.address=console.neon.tech
      distilled.decode 0.0ms ERROR "try again" error.type=ServiceUnavailable
    distilled.retry.backoff 67.9ms unset distilled.retry.attempt=2 distilled.retry.delay_ms=68 distilled.retry.reason=ServiceUnavailable
    distilled.attempt 0.1ms unset distilled.attempt=3 http.request.resend_count=2 http.response.status_code=200
      distilled.credentials 0.0ms unset
      distilled.request.build 0.0ms unset
      distilled.transport 0.0ms unset http.request.method=GET http.response.status_code=200 server.address=console.neon.tech
      distilled.decode 0.0ms unset
trace 53610d6d046855485722cfa9279d932c
  distilled.pagination 0.8ms unset distilled.pagination.items=3 distilled.pagination.kind=items distilled.pagination.mode=cursor distilled.pagination.operation=Neon.ListP
    Neon.ListProjects client 0.2ms unset http.request.method=GET http.response.status_code=200 rpc.method=Neon/ListProjects rpc.system.name=neon-api server.address=consol
  ... (identical to rex)
```

## Distilled tests ported

- `retry.test.ts`, `retry-after.test.ts`: in `retry_spec`, through a real client over the
  scripted transport, with random pinned the same way.
- `pagination.test.ts` (cursor, nextLink, keyset scenarios), and the Link-header and
  raw-body-member cases of `protocol-rest.test.ts`: in `paginate_spec` and `rest_spec`.
- `protocol-rest.test.ts`: request encoding, success decoding, response header members,
  raw and binary outputs, label refusal, typed error matching, error response fields,
  status mapping and fallbacks, and the envelope/status_map options. All are in
  `rest_spec` under the same names.
- `telemetry.ts` operationInfo rules: in `operation_spec`.

### Not ported (and why)

- "resolves credentials on every request from the calling fiber's context": there are no
  fibers. The Lua equivalent (credentials per client, resolved per call) is
  "resolves credentials per call from the calling client".
- The "body read failure" cases (HttpClientError): a Lua transport returns the whole body
  or `nil, err`, so no stream can fail half-way. Transport failures are task 05.
- "a typed body gets its keys mapped" / "a typed body that is not JSON stays the raw
  text": error classes have no body schema here. `err.body` is the parsed JSON or the
  text.
- "an Extend input sends the base struct's fields": the generator flattens extended
  structs (task 06). The raw request-body cases are task 03's (`request_spec`).

## Skipped / not verified

- No live API calls and no network, by design. The curl and Rex transports (task 05) are
  not exercised here; every call goes over `distilled.testing` transports.
- The default `host.sleep` is a busy wait. It is checked only for a 10 ms wait.
- The `tracing = "debug"` console exporter (stderr) is checked only for its level and
  service name, not for its output text.

## Open problems / proposals (also in STATUS.md 04)

- A tracer API `attach(span)`/`detach(span)` is proposed. `paginate.lua` currently
  touches `rawget(tracer, "_stack")`.
- `docs/interfaces.md` should record the protocol's third return value `meta = {status,
  headers}`, the `env_fallback` rule for secret options, and that provider options cannot
  reuse common option names.
- The task 03 fixture gives `op.span` as `"Neon.GetProject"` with no
  `telemetry.prefix`. Generated services should emit the prefix and the model op name.
