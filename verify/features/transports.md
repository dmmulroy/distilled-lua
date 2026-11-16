# Transports (`distilled.transport.*`) and `dl serve`

## Sub-features

- `transport(request) -> response | nil, err` with the contract in `docs/interfaces.md`
  (Host): `request = { method, url, headers, body, timeout }`, `response = { status,
  headers, body }`.
- `distilled.transport.popen_curl([opts])`: stock Lua / LuaJIT, through `io.popen`.
  `opts = { curl, follow_redirects, max_redirects, tmpdir }`.
- `distilled.transport.exec_curl(exec [, opts])`: over any `exec(argv, { stdin, timeout })`
  with `rex.exec`'s contract. `opts = { curl, margin_s = 2, follow_redirects }`.
- `distilled.transport.curl_common`: `check` (request validation, `InvalidInput`),
  `config` (the curl config text), `parse` (curl output to a response), `failure`
  (`TransportError`), `scrub` (removes request secrets from a message).
- Secrets never in process arguments: URL, method and headers go in the curl config, read
  from stdin (`exec_curl`) or a 0600 temp file (`popen_curl`); the body is read by curl
  from a file (`data-binary = "@..."`): `/dev/fd/3` for `exec_curl`, a 0600 temp file for
  `popen_curl`. argv is only `curl -q --config -|<path>` (or `sh -c <fixed script> sh <n>
  curl`).
- Responses: status from the last header block (1xx and redirect blocks skipped),
  lowercased header names, repeated headers joined with `", "`, body as exact bytes (cut
  by curl's `size_download`, so binary, empty and header-looking bodies are safe). No
  `--fail`: error bodies come through. Redirects are not followed unless asked.
- `request.timeout` -> curl `max-time`; for `exec_curl` also the exec timeout plus
  `margin_s`.
- Failures: `TransportError` with curl's stderr line (scrubbed), `err.curl_code`,
  `err.timeout = true` (and category `TimeoutError`) for exit 28 or a killed process,
  `err.tls = true` for TLS codes, "curl not found" for a missing binary.
- `verify/lib/serve.py` (`dl serve`): scripted responses per path (status, headers incl.
  repeats, body / body_b64 / json, delay, drop, 100 Continue, stall), echo, mirror,
  pattern bytes, status, slow, drop, request log; `verify/lib/serve.lua` drives it from Lua
  and has `popen_exec`, an `io.popen` shim with `rex.exec`'s contract.

## How a user reaches it

```lua
-- stock Lua
local client = Neon.new{ host = { transport = require("distilled.transport.popen_curl")() } }
-- Rex
local client = Neon.new{ host = require("distilled.host.rex")() }
-- any exec function with rex.exec's contract
local tr = require("distilled.transport.exec_curl")(my_exec, { curl = "/usr/bin/curl" })
```

## Driving it with `dl`

- `verify/dl test transport` runs the offline cases (config escaping, parsing of multiple
  header blocks, failure mapping, the argv/stdin split on a fake exec) and reports the HTTP
  cases as pending.
- `verify/dl test transport --http` starts a private `dl serve` and runs every case against
  it: popen_curl and exec_curl (popen shim) under lua and luajit, exec_curl over rex.exec
  under Rex. Methods, HEAD, exact headers (quotes, backslashes, UTF-8, empty), path and
  query bytes, JSON and all-256-byte bodies both ways, empty bodies, 204, error statuses
  with bodies, 302 unfollowed, repeated response headers, 100 Continue, non-ASCII,
  timeout, refused, dropped connection, 5 MiB each way, the server's request log, and (lua
  and luajit) that popen_curl's temp files are 0600 while curl runs and gone afterwards.
- `verify/dl serve start|stop|url`, `verify/dl serve run <cmd>` for ad-hoc use:
  `curl -XPOST $DL_SERVE_URL/_dl/script -d '{"path":"/x","responses":[{"status":500}]}'`.
- `verify/dl canary <script>` proves the key is not in argv (ps samples) or temp files.

## Gotchas

- io.popen is one-way, so popen_curl uses temp files; mktemp (mkstemp) creates them 0600.
  They are removed by a scope finalizer, but a process killed mid-request leaves them in
  `$TMPDIR` (exec_curl writes nothing to disk).
- curl's config: `name:` with an empty value *removes* a header; empty values are sent as
  `name;`. `request = "HEAD"` hangs waiting for a body; HEAD uses `head`. `data-binary`
  adds a form content type unless `Content-Type:` is cleared, and curl adds `Expect:
  100-continue` to large bodies (cleared too). `-q` must be the first argument or
  `~/.curlrc` is read. `globoff` keeps `[]{}` in URLs literal.
- The trailer marker is full of `-`: it is found with a plain `string.find`, never as a
  pattern.
- `exec_curl` with a body runs `dd bs=1 count=<config bytes>` so dd never reads past the
  config into the body; curl then reads the body from `/dev/fd/3` (the original stdin).
- Python's http.server decodes header bytes as latin-1; serve.py re-encodes them so echo
  shows the UTF-8 that was sent. Non-ASCII *response* header values are not supported by
  serve.py.
- gopher-lua's `os.clock` is wall time, lua's is CPU time: timing assertions in specs use
  `os.time` (whole seconds).
