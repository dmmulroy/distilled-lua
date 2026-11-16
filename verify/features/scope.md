# Scope (`distilled.scope`)

## Sub-features

- `Scope.new()`, `scope:defer(fn)` (fn receives the close reason or nil).
- `scope:close([err])`: finalizers newest first, each under `compat.pcall`; returns `true`
  or `nil, errs` (what the failing finalizers raised); idempotent.
- Deferring on a closed scope runs the finalizer at once.
- `Scope.with(fn)` / `distilled.scope(fn)`: bracket; closes on return (passing every return
  value through, including `nil, err`) and on a raise (re-raising the original value at
  level 0). A failing finalizer never replaces fn's error or results.

## How a user reaches it

```lua
local distilled = require("distilled")
distilled.scope(function(scope)
  scope:defer(function() os.remove(tmp) end)
  ...
end)
```

## Driving it with `dl`

- `verify/dl test scope` runs `spec/scope_spec.lua`: order, reasons, raising finalizers,
  idempotence, late defer, re-raise identity for tables and strings.

## Gotchas

- Lua 5.1 cannot yield across `pcall`/`xpcall`, so code inside `Scope.with` must not yield
  (the core is synchronous, so it does not).
- Scope uses `compat.pcall` (xpcall) because a plain `pcall` that catches an error in
  gopher-lua breaks the upvalues of closures created earlier in running frames.
- A finalizer's error is reported from `close` but not raised; `Scope.with` drops
  finalizer errors in favour of fn's outcome.
