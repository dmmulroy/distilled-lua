# Task 05: transports, the Rex host, and the tools that exercise them

You build the only parts that touch the outside world: the two curl transports, the optional
Rex host adapter, the OTLP exporter, and the verification commands that drive real HTTP
against a local fixture server. Tasks 01-04 are finished; read their done files and
`STATUS.md` first. Task 06 (the generator) runs at the same time as you in this working
tree, so stay inside your files.

Read `AGENTS.md`, `../distilled-lua-plan.md` ("Calling it from Rex", "Rex research",
"Verification toolkit"), and the Host section of `docs/interfaces.md`. Rex's Lua reference:
`curl -s https://www.superlogical.com/rex/docs/reference/lua.md`.

## Files you own

```text
lua/distilled/transport/curl_common.lua   curl config text, response parsing (shared)
lua/distilled/transport/popen_curl.lua    stock Lua: io.popen
lua/distilled/transport/exec_curl.lua     takes exec(argv, opts): works with rex.exec
lua/distilled/host/rex.lua                optional; the ONLY file that may name `rex`
lua/distilled/trace/otlp_http.lua         exporter (register it in exporters.lua with a one-line hook)
verify/dl: the `serve`, `rex`, `canary`, `jaeger` commands only (replace the stubs)
verify/lib/serve.*    verify/lib/canary.*    verify/features/{transports,rex-host,otlp}.md
spec/{transport,rex_host,otlp_http}_spec.lua   examples/rex_action.lua
STATUS.md (your section)
```

## Requirements

1. **curl transports.** Both build the same curl config and parse the same output; the
   difference is only how the process is started.
   - The URL, method, every header and the body go to curl through `--config -` on standard
     input (and the body through a temp file or stdin as needed), never as process
     arguments, so secrets never appear in `ps`. Escape config values correctly (quotes,
     backslashes, newlines); a header value containing a newline is `InvalidInput`.
   - `popen_curl` has no way to write stdin and read stdout through one `io.popen`. Solve
     it (for example a temp config file with `0600` permissions created safely, removed in
     a scope finalizer) and explain the choice. Temp files must not be world-readable at
     any moment and must be removed on every path.
   - Response: status, headers (lowercased; repeated headers joined with `, `), body as
     exact bytes including binary and empty bodies. Handle `100 Continue` and redirects'
     multiple header blocks (do not follow redirects by default). Do not let curl's
     `--fail` hide error bodies.
   - `request.timeout` maps to curl's `--max-time`, and for `exec_curl` also to the exec
     timeout with a small margin.
   - Failures (curl missing, DNS, refused, timeout, TLS) are `nil, err` with tag
     `TransportError`, a message from curl's stderr with nothing secret in it, and
     `err.timeout = true` for timeouts.
   - Large bodies: no quadratic string handling; a 5 MB response must work.
2. **`host/rex.lua`**: `require("distilled.host.rex")()` returns a host table: the
   `exec_curl` transport over `rex.exec`, `exec = rex.exec`, `now = os.clock` (wall time in
   Rex), `epoch`, and `sleep` using `rex.sleep` when it exists (scripts) and
   `rex.exec({ "sleep", s })` otherwise (config file). It must fail with a clear message
   when the global `rex` is absent.
3. **`dl serve`**: a local HTTP fixture server for tests, started on a free port and
   stopped cleanly (`dl serve start` prints the port; `dl serve stop`; or `dl serve run
   <script>` that starts it, runs a command with the port in an environment variable, and
   stops it). Scriptable per path: a sequence of responses (status, headers, body, delay),
   echo of the received request (method, path, query, headers, body) so tests can assert
   what curl actually sent, binary bodies, slow responses for timeout tests, and a
   connection drop. Use `python3` or `node` (both installed); no packages to install.
4. **Transport specs against `dl serve`**, under all three runtimes (`popen_curl` under
   `lua` and `luajit`; `exec_curl` under Rex with `rex.exec`, and under `lua` with a small
   `io.popen`-based exec shim so the same code path is covered): methods, headers,
   JSON and binary bodies both ways, empty bodies, non-ASCII, status codes, timeouts,
   refused connection, large body. These specs need the server, so gate them behind an
   environment variable that `dl test --http` sets after starting `dl serve`; plain
   `dl test` skips them and says so.
5. **End to end over real HTTP:** using the fixture service from task 03/04 pointed at
   `dl serve`, call operations through the full client (retry on a scripted `500, 500,
   200`, a paginated listing, a typed error) under each runtime, asserting on the trace.
6. **`dl rex <script.lua> [--action NAME]`**: runs a script or an action through `rex do`
   with `package.path` set for this repo, without touching `~/.config/rex`. Write
   `examples/rex_action.lua`: it defines a `rex.action` that uses the client with
   `distilled.host.rex` against `dl serve` and returns a result, and show it working with
   `rex do examples/rex_action.lua --action NAME`. Measure and record: does a 3-second
   request inside the action block other Rex commands meanwhile (run `rex ls` during it)?
7. **`dl canary`**: runs a given script with a known fake key (`sk-CANARY-...`) configured
   as the API key and debug tracing on, then searches everything the run produced (stdout,
   stderr, the trace file, error messages, and a `ps` sample taken while a slow request is
   in flight) for the key. Exit non-zero when found, printing where. The key must reach the
   fixture server in the `authorization` header (assert that too, or the test proves nothing).
8. **`otlp_http` exporter**: POSTs OTLP/JSON to `<endpoint>/v1/traces` through a transport,
   untraced (no recursion), failures returned not raised. Test against `dl serve`.
   **`dl jaeger start|stop|url`**: runs Jaeger all-in-one in Docker with OTLP HTTP on 4318.
   If Docker is not running, say so and skip; do not try to start Docker. If it is
   available, export one trace and confirm through Jaeger's query API that it arrived.

## Done means

- `verify/dl doctor` clean; `verify/dl test` and `verify/dl test --http` green in all three runtimes.
- `verify/dl canary` clean on the end-to-end script.
- `tasks/05-host.done.md` committed with the command output, the Rex blocking measurement,
  the Jaeger result or the reason it was skipped, and anything else skipped.
