# Using a client from Rex

[Rex](https://www.superlogical.com/rex/) runs Lua (gopher-lua, Lua 5.1) in its
configuration file and in `rex do` scripts. distilled-lua runs there unchanged; one
adapter, `distilled.host.rex`, supplies HTTP and sleep through `rex.exec`.

Every snippet below is part of a file under `examples/` that was run as shown; nothing
here touched `~/.config/rex` (the examples load a vendored tree from `/tmp/dlv/vendor` and
talk to the local fixture server `verify/dl serve` instead of Neon).

## 1. Vendor the runtime and the client

The configuration loads modules from disk with `package.path`, so copy them next to it:

```sh
lua bin/distilled-lua vendor --out ~/.config/rex/vendor          # lua/distilled/ minus gen/ and testing/
lua bin/distilled-lua generate --model models/neon.json --provider providers/neon.lua \
  --ops list_projects,get_project,create_project --out ~/.config/rex/vendor/neon
```

`--ops` keeps only the operations you use and the shapes they reach: the full Neon
client is 630 KB of files (250 KB of it `service.lua`, the part that is loaded); the
three operations above are 74 KB of files with a 24 KB `service.lua` that loads in about
a millisecond in Rex (`types.lua` is for the language server and never loaded). Re-run both commands after updating distilled-lua. Tested the same
way into `/tmp/dlv/vendor` (all 178 operations): `examples/vendored_client.lua` loads it
with nothing else on `package.path` under lua, luajit and `rex do`, and checks that
`distilled.testing`, `distilled.gen` and `verify/` are not there.

## 2. The configuration

From `examples/rex_neon_action.lua`:

```lua
local home = os.getenv("HOME")
local vendor = os.getenv("DISTILLED_VENDOR") or (home .. "/.config/rex/vendor")
package.path = vendor .. "/?.lua;" .. vendor .. "/?/init.lua;" .. package.path

local distilled = require("distilled")
local Neon = require("neon")

-- Built once when the configuration loads. The key is read from the environment of the
-- Rex *server* (or use api_key = require("distilled.credentials").from_file(path)).
local neon = Neon.new({
  host = require("distilled.host.rex")(),
  deadline_s = 20, -- retries and their sleeps stop before Rex's 30 s action limit
  tracing = {
    level = "operation",
    file = (os.getenv("DISTILLED_TRACE_DIR") or "/tmp") .. "/neon-traces.jsonl",
    max_bytes = 1000000,
  },
})

rex.action({
  name = "neon_projects",
  title = "Neon: list projects",
  run = function()
    -- distilled.check turns nil, err into a plain error string, which is what Rex shows
    local projects = distilled.check(neon:list_projects_items({ limit = 2 }):collect(20))
    local names = {}
    for i, p in ipairs(projects) do
      names[i] = p.name
    end
    return names
  end,
})

rex.action({
  name = "neon_project",
  title = "Neon: show a project",
  args = { project_id = "string" },
  run = function(_, args)
    local res = distilled.check(neon:get_project({ project_id = args.project_id }))
    return { id = res.project.id, name = res.project.name }
  end,
})
```

How it was run (`examples/serve_neon_fixture.lua` scripts the fixture server: two pages of
projects, a project that answers 503 then 429 with `Retry-After: 1` before succeeding,
and a missing one):

```text
$ verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
    DISTILLED_VENDOR=/tmp/dlv/vendor NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon \
    rex do examples/rex_neon_action.lua --action neon_projects; ...'
["Project quiet-sun","Project late-moon","Project red-star"]                    (exit 0)
Error: NotFound: project not found [trace 8774dff43ccde9927c75efe2f0c68377]     (exit 1, project_id=missing)
{"id":"quiet-sun","name":"Quiet Sun"}                                           (exit 0, after two retries)
```

## 3. The host adapter

`require("distilled.host.rex")([opts])` returns a host (see `docs/usage.md`, "The host
seam") with:

- `transport`: `distilled.transport.exec_curl` over `rex.exec`. curl reads its
  configuration (URL, headers with the key) and the body on stdin, so nothing secret is in
  the process list or on disk. `opts` (`curl`, `margin_s`) go to it.
- `sleep`: `rex.sleep` in `rex do` scripts; in the configuration file, where `rex.sleep`
  is nil, `rex.exec({ "sleep", s })`, which waits while the server keeps handling keys
  and other actions.
- `now = os.clock` (wall time in gopher-lua), `epoch = os.time`, `exec = rex.exec` (for
  `credentials.from_command`), `getenv = os.getenv`.

Outside Rex it raises a clear error. `io.popen` and `os.execute` raise inside Rex, so
`distilled.host.popen` does not work there.

## 4. Limits to design for

| Rex fact | What to do |
| --- | --- |
| An action may run 30 seconds, waits included, then fails with `timeout` | Set `deadline_s` (20 above): retries stop in time and each request's curl timeout is the time left |
| A Lua function bound directly to a key may run only 5 seconds | Bind keys to the action, not to a function that calls the API |
| `os.getenv` reads the environment of the Rex **server**, not your shell | Start the server with `NEON_API_KEY` set, or read the key from a file: `api_key = require("distilled.credentials").from_file(home .. "/.config/neon/key")` |
| A failed action shows a string; a raised table prints as `table: 0x...`, and `assert(nil, err)` fails with "string expected, got table" | Raise with `distilled.check(value, err)` (or `error(tostring(err), 0)`). `check` raises the bare message, `NotFound: project not found [trace <id>]`, with no `file:line:` prefix pointing into the library |
| Commands an action started are stopped when it returns; there are no timers in the configuration | Calls are synchronous and finish inside the action; traces are flushed when each call returns |
| Reloading the configuration while an action runs fails it with `conflict` | Nothing to do; expect it while editing |

A blocking request inside an action does not freeze Rex: measured in task 05, a 3-second
request inside a `rex do --action` action left `rex ls` answering in 0.05 s.

## 5. Tracing to a file

Tracing is off by default, in Rex too. The long form of `tracing` writes OTLP/JSON lines
to a file, truncating it once it passes `max_bytes`; the client in section 2 does this.
When tracing is on, a failed call's error carries `trace_id` and its string ends with
`[trace <id>]`, so the message Rex shows points at the trace. Read the file as a tree:

```text
$ verify/dl trace --file /tmp/neon-traces.jsonl
trace caec5e048cb4b4ffe85299e2cfa05029
  distilled.pagination 28.5ms unset distilled.pagination.items=3 distilled.pagination.kind=items ...
    Neon.ListProjects client 15.7ms unset http.request.method=GET http.response.status_code=200 ...
    Neon.ListProjects client 11.8ms unset http.request.method=GET http.response.status_code=200 ...
trace 8774dff43ccde9927c75efe2f0c68377
  Neon.GetProject client 11.5ms ERROR "project not found" error.type=NotFound ... neon.project_id=missing ...
trace 9f65c5c80e96b75e89b1c40948bc640a
  Neon.GetProject client 1087.1ms unset distilled.attempts=3 distilled.retry.delay_ms=1034
    distilled.retry.errors=[ServiceUnavailable,TooManyRequests] ...
(5 spans from /tmp/neon-traces.jsonl)
```

Use `level = "debug"` for per-attempt, credential, build, transport and decode spans
(`docs/tracing.md`). Keep the file in a directory the server can write.

## Trying things without touching your configuration

`verify/dl rex <script> [--action NAME] [key=value ...]` runs `rex do` with this repository
on `LUA_PATH`; `--serve` starts a private fixture server first (`examples/rex_action.lua`
is a self-contained demo that scripts the server itself:
`verify/dl rex --serve examples/rex_action.lua --action distilled_demo`).
