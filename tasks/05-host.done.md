# Task 05: transports, the Rex host, and the tools that exercise them (done)

## What was built

| File | What |
| --- | --- |
| `lua/distilled/transport/curl_common.lua` | request check (`InvalidInput`), curl config text (quoting, empty headers as `name;`, `head` for HEAD, `Expect:` and form content type cleared, `globoff`, `proto`, `max-time`, optional redirects), output parsing (header blocks, 1xx/redirect blocks skipped, lowercased names, repeats joined with `, `, body cut by curl's `size_download`), `TransportError` mapping (`curl_code`, `timeout` + `TimeoutError` category, `tls`, curl not found), `scrub` (header values, query, userinfo, short body removed from messages) |
| `lua/distilled/transport/popen_curl.lua` | stock Lua: config, body and stderr in `mktemp` files (0600 from creation), removed by a scope finalizer; argv is `curl -q --config <path>` |
| `lua/distilled/transport/exec_curl.lua` | over `exec(argv, { stdin, timeout })`: config on stdin; with a body, stdin = config..body and `sh -c 'exec 3<&0; dd bs=1 count=N \| curl -q --config -'` with `data-binary = "@/dev/fd/3"` (nothing on disk); exec timeout = `request.timeout + margin_s` (2) |
| `lua/distilled/host/rex.lua` | `{ transport, exec, sleep, now = os.clock, epoch = os.time, getenv, name }`; `rex.sleep` in scripts, `rex.exec{ "sleep", s }` in config; clear error without `rex` |
| `lua/distilled/trace/otlp_http.lua` (+ one hook in `exporters.lua`) | POST OTLP/JSON to `<endpoint>/v1/traces`, untraced, failures returned as `SdkError` (non-2xx, transport, `partialSuccess.rejectedSpans`) |
| `verify/dl` | `serve start\|stop\|port\|url\|run`, `rex [--serve]`, `canary [--runtime] [--keep]`, `jaeger start\|stop\|url\|check`; `test --http` (shared `cmd_test`, minimal edit); help text |
| `verify/lib/serve.py` | fixture server (stdlib only): scripted responses per path (status, headers with repeats, body/body_b64/json, delay, drop, 100 Continue, stall), echo, mirror, pattern bytes, status, slow, drop, request log, reset |
| `verify/lib/serve.lua` | Lua control client, `popen_exec` (rex.exec contract over io.popen), `pattern_bytes`, `fixture_class()` |
| `verify/lib/canary.lua`, `canary_e2e.lua`, `canary_transport.lua`, `canary_leaky.lua` | canary helpers; the end-to-end client script; a transport-level script; a script that leaks on purpose (must fail) |
| `verify/lib/jaeger_check.lua` | exports one trace and polls Jaeger's `/api/traces/<id>` (outside my listed files; the `dl jaeger` brief needs it) |
| `spec/transport_spec.lua`, `spec/rex_host_spec.lua`, `spec/otlp_http_spec.lua` | offline cases always; HTTP cases when `DL_SERVE_URL` is set |
| `examples/rex_action.lua` | `rex.action` `distilled_demo` using the client with `distilled.host.rex` against dl serve |
| `verify/features/{transports,rex-host,otlp}.md` | feature map |

## Proof bar (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test                       (exit 0)
== summary
  lua: ok 986 passed, 3 pending [Lua 5.5]
  luajit: ok 986 passed, 3 pending [luajit]
  rex: ok 986 passed, 6 pending [rex]

$ verify/dl test --http                (exit 0)
== summary
  lua: ok 1031 passed [Lua 5.5]
  luajit: ok 1031 passed [luajit]
  rex: ok 1009 passed, 2 pending [rex]
```

Pending without `--http`: my three HTTP groups (transport, client end to end, otlp_http)
say "skipped: DL_SERVE_URL is not set (run verify/dl test --http)"; under Rex also the
rex_host HTTP case and two pending specs of other tasks (regex Node differential,
`bin/distilled-lua` under Rex). With `--http` only those two others remain pending.
Rex runs fewer transport cases than lua/luajit because lua/luajit cover two transports
(popen_curl and exec_curl over the popen shim) and Rex one (exec_curl over rex.exec).

My areas alone:

```text
$ verify/dl test transport_spec --http   lua 66 · luajit 66 · rex 46 passed
$ verify/dl test rex_host_spec --http    lua 5 · luajit 5 · rex 8 passed
$ verify/dl test otlp_http_spec --http   lua 10 · luajit 10 · rex 10 passed
$ verify/dl test transport_spec          lua 25 · luajit 25 · rex 26 passed, 2 pending each
$ stylua --check (every file I touched)  clean
```

### What the HTTP specs exercise (per transport, against dl serve)

GET/POST/PUT/PATCH/DELETE/OPTIONS and HEAD (empty body, content-length kept); headers
exactly as sent (quotes, backslashes, UTF-8, empty value) and no `Expect` / form
content type added; path and query bytes (`%2F`, `%C3%A9`, `[]`); JSON both ways;
all 256 byte values both ways; empty request body (`content-length: 0`) vs no body; 204
and empty 200; 404/500/503 bodies come through (no `--fail`), `Retry-After` kept; 302
not followed, followed with `follow_redirects`; repeated response headers joined,
names lowercased, `100 Continue` skipped; timeout (0.5 s against a 4 s answer:
`err.timeout`); refused (`curl_code` 7, no secret in the message even with the key in the
URL and header); dropped connection (52); TLS failure (https to the plain port,
`err.tls`); 5 MiB upload mirrored and 5 MB download compared byte for byte; the
server's request log matches what was sent; popen_curl temp files are `-rw-------`
while curl runs (a wrapper "curl" lists them) and gone after success and failure.

### End to end over real HTTP (requirement 5)

`spec/transport_spec.lua` "client end to end over HTTP: <transport>": the fixture service
from task 03 as a client (`serve.fixture_class()`), `base_url` at dl serve, the real
transport, a recording `sleep`, debug tracing into a memory exporter. Under lua (popen_curl
and exec_curl shim), luajit (same) and Rex (exec_curl over rex.exec):

- `500, 500, 200`: value returned; two sleeps; op span ok with
  `http.response.status_code=200`, three `distilled.attempt` children, three
  `distilled.transport` spans; the server saw three GETs with `authorization: Bearer <key>`.
- cursor pagination over three pages: three items; the server saw `limit=2`, then
  `cursor=c1`, `cursor=c2`; three page spans.
- 404: `NotFound`, `status = 404`, `err.trace_id` set; span `failed("NotFound")`.
- refused connection through the client: `TransportError`.
- Every trace checked with `no_attr_contains(<key>)`.

## Canary

```text
$ verify/dl canary verify/lib/canary_e2e.lua          (exit 0)
ok   canary lua: key absent from stdout, stderr, trace (8 lines), 12 curl ps entries; reached the server
ok   canary luajit: key absent from stdout, stderr, trace (8 lines), 12 curl ps entries; reached the server
ok   canary rex: key absent from stdout, stderr, trace (8 lines), 12 curl ps entries; reached the server

$ verify/dl canary verify/lib/canary_leaky.lua --runtime rex      (exit 1, as it must)
FAIL canary rex: key in stdout.txt (lines 1 )
FAIL canary rex: key in the trace file (lines 1 )
FAIL canary rex: key in a process command line (ps sample lines 1980 2977 3973 4969 5965 )
```

The canary key is `sk-CANARY-<24 random hex>`. The script runs with `TMPDIR` set to a
private directory, so any temp file left behind is reported, and its contents are searched
too. `ps -axww` is sampled every 50 ms; the check fails if no curl process was sampled
(the script makes a 1.5 s call). The positive control parses dl serve's request log
and fails unless the key arrived in an `authorization` header. The e2e script makes a
retried call, a listing, a typed error, a slow call, a sensitive output (`<redacted>`)
and a refused connection, and prints every result and error field. The first version of
`canary_transport.lua` put the full URL (`?api_key=<key>`) in a span attribute, and the
canary caught it (`key in the trace file`). That was a bug in the script, not in the
library.

## Rex

```text
$ verify/dl rex --serve examples/rex_action.lua --action distilled_demo
{"projects":["quiet-sun","late-moon","red-star"],"retried":"Quiet Sun","seconds":0.09}
```

(listing over two pages, plus a call that got 503 and 500 before it succeeded.) `dl rex`
sets `LUA_PATH` (measured: gopher-lua honours it) and runs `rex do`. Nothing under
`~/.config/rex` is read or written.

**Blocking measurement.** I started the action with a 3-second request, then ran `rex ls`
four times and `rex do -e` once while it was in flight:

```text
rex ls #1 at +1.04s exit=0 took 0.054s
rex ls #2 at +1.57s exit=0 took 0.057s
rex ls #3 at +2.12s exit=0 took 0.052s
rex ls #4 at +2.66s exit=0 took 0.055s
rex do -e at +3.20s took 0.088s
{"projects":["quiet-sun","late-moon","red-star"],"retried":"Quiet Sun","seconds":3.171}
action finished at +3.53s
```

So a slow request inside a `rex do --action` action does not block other Rex commands. An
earlier probe with the bare transport gave the same result (0.055-0.071 s).

## Jaeger

```text
$ verify/dl jaeger start      -> dl jaeger: skipped: the Docker daemon is not running (dl does not start it)   exit 3
$ verify/dl jaeger check      -> same, exit 3
```

**Skipped:** the Jaeger round trip, because Docker is installed but its daemon is not
running, and the brief forbids starting it. The closest checks that did run:

- `otlp_http_spec` "over HTTP": dl serve received the export, and it decodes back with
  `otlp.decode` (span names, parent ids).
- `jaeger_check.lua` against dl serve standing in for Jaeger
  (`DL_JAEGER_OTLP`/`DL_JAEGER_QUERY` pointed at it). It exported, then polled
  `/api/traces/<id>` 40 times and reported "not found", as expected, with exit 1. This
  covers the script's export and poll path, but not Jaeger's answer format.

## Measured runtime facts (new)

- `rex.exec` stdout and stdin are byte-exact (NUL, 0xFF, CR LF), and a 5 MB stdout
  works. A missing program returns `nil, "<prog>: executable file not found in PATH"`.
  A timeout sends SIGTERM and gives `code = -1`, `timed_out = true`,
  `signal = "SIGTERM"`. `rex.exec` is a callable table (it has `.start`).
- `os.getenv` in a `rex do` script reads the `rex do` process's environment, so `dl test
  --http` reaches Rex specs through `DL_SERVE_URL`.
- Python's `http.server` decodes header bytes as latin-1. serve.py re-encodes them.

## Skipped, and why

- The Jaeger round trip: no Docker daemon (see above).
- The configuration-file action (as opposed to `rex do --action`) was not run, because
  the brief forbids editing `~/.config/rex`. Its `rex.exec{ "sleep" }` path is covered by
  a Rex spec that uses the real `rex.exec` with `rex.sleep` hidden.
- DNS failure: resolving a name needs the system resolver, which may go to the network.
  curl's code 6 goes through the same generic `TransportError` path as code 7, which is
  tested.
- Non-ASCII response header values: serve.py cannot send them (latin-1 only).
- The exec shim (`serve.popen_exec`) does not enforce `timeout` (curl's `--max-time`
  does). Exec-level timeouts are tested with a fake exec, and against real `rex.exec`
  in the probe above.

## Open problems / proposals (also in STATUS.md)

- `verify/features/README.md` (owned by task 04 now) should list `transports.md`,
  `rex-host.md` and `otlp.md`.
- Stock Lua has no default transport or sleep in `distilled.host`. A
  `distilled.host.popen` (popen_curl + a shell sleep) would give scripts a one-line
  host; `verify/lib/canary.lua` has one for the verify scripts.
- The header comment of `lua/distilled/trace/exporters.lua` still says otlp_http arrives
  later. I added only the hook.
- popen_curl's temp files survive a process killed mid-request (`kill -9`); exec_curl
  writes nothing to disk.
