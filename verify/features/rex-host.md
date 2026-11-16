# Rex host (`distilled.host.rex`) and `dl rex`

## Sub-features

- `require("distilled.host.rex")([opts])` returns a host: `transport` (exec_curl over
  `rex.exec`), `exec` (rex.exec, wrapped as a plain function: Rex's is a callable table
  with `.start`), `now = os.clock` (wall time in gopher-lua), `epoch = os.time`, `sleep`
  (`rex.sleep` in `rex do` scripts, `rex.exec{ "sleep", s }` in the configuration file,
  where `rex.sleep` is nil), `getenv`. `random` is left to `distilled.host`'s default
  (math.random's seed is fixed on some runtimes, which would repeat trace ids).
- Raises a clear message when the global `rex` (or `rex.exec`) is missing.
- The only file in the library that names `rex`.
- `examples/rex_action.lua`: a `rex.action` using the client with this host against
  `dl serve`.

## How a user reaches it

```lua
-- ~/.config/rex/init.lua (see ../distilled-lua-plan.md "Calling it from Rex")
local neon = Neon.new{ host = require("distilled.host.rex")(), retry = { deadline_s = 20 } }
rex.action{ name = "neon_projects", title = "Neon: List Projects", run = function()
  return distilled.check(neon:list_projects_items{}:collect(20))
end }
```

## Driving it with `dl`

- `verify/dl test rex_host` (fake `rex` under lua/luajit; real Rex for wall-clock sleep
  in both modes) and `verify/dl test rex_host --http` (a request through rex.exec).
- `verify/dl rex [--serve] <script.lua> [--action NAME] [k=v ...]`: `rex do` with
  `LUA_PATH` pointing at this repo; `--serve` wraps it in `dl serve run`. Nothing under
  `~/.config/rex` is read or written.
- `verify/dl rex --serve examples/rex_action.lua --action distilled_demo`.

## Gotchas

- `rex do` honours `LUA_PATH` and adds the script's directory to `package.path`.
- `os.getenv` in a `rex do` script reads the `rex do` process's environment (measured:
  a variable set only on the command line is visible), not the server's. In the
  configuration file it is the server's.
- Blocking (measured, task 05): a 3-second request inside an action run by `rex do
  --action` does not block other Rex commands: `rex ls` during it took 0.05-0.07 s. The
  configuration-file case is documented as non-blocking by Rex ("the server keeps handling
  keys and other actions") and was not measured, because the brief forbids editing
  `~/.config/rex`.
- Actions time out after 30 s: give the client `retry = { deadline_s = 20 }` or less.
- Action errors must be strings: `distilled.check(...)` or `error(tostring(err), 0)`.
