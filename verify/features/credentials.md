# Credentials (`distilled.credentials`)

## Sub-features

- A source is a string, a secret, or `fn(host) -> value | nil, err`. `resolve(source, host,
  name)` returns a secret or `nil, err`: `nil, "message"` becomes `ConfigError`, a raise
  becomes `SdkError`, an empty value is `ConfigError`.
- `from_env(name)` (through `host.getenv`), `from_file(path)` (trailing whitespace
  trimmed), `from_command(argv, { timeout })` (through `host.exec`; `ConfigError` when the
  host has none).
- The client cache: a cell per secret option, resolved on first use, shared with clients
  derived by `with` unless the option is overridden.
- Refresh on 401: a call that fails with `Unauthorized` while a source is a function
  clears the cache, resolves once more and retries the call a single time
  (`distilled.credentials.refreshed = true` on the operation span).
- Option specs in `Client.define`: `{ secret, env, default, required, type }`. An option
  without a value reads `env` (a function source, so a rotated variable is picked up on
  refresh); a missing required option fails the call with `ConfigError`, `err.key` the
  option name, the message naming the variable.

## How a user reaches it

```lua
local credentials = require("distilled.credentials")
Neon.new{ api_key = credentials.from_file(os.getenv("HOME") .. "/.neon-key") }
Neon.new{ api_key = credentials.from_command{ "op", "read", "op://dev/neon/key" },
          host = require("distilled.host.rex")() }
Neon.new{ api_key = function(host) return fetch_token(host) end }
```

## Driving it with `dl`

- `verify/dl test credentials_spec`: sources and their failures, the cache, derived
  clients, env fallback, refresh-on-401 (with a debug trace: two attempts, two
  `distilled.credentials` spans, no key in any span), one refresh only, fixed values never
  refreshed, and canary checks on errors and traces.

## Gotchas

- Errors never quote a value, a file's contents or a command's output; `from_command`
  reports the program and exit code only.
- `from_file` uses `io.open`, which works in Rex; `from_command` needs `host.exec`.
- A refresh that fails returns the refresh failure, not the 401.
