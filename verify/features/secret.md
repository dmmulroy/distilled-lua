# Secrets (`distilled.secret`)

## Sub-features

- `secret.wrap(v)` (also `secret(v)` and `distilled.secret(v)`): a wrapper whose
  `tostring` and concatenation give `<redacted>`; wrapping a secret returns it.
- `secret.unwrap(v)`: the value, or `v` itself when it is not a secret.
- `secret.is(v)`.
- `secret.unwrap_deep(v)`: a copy with every secret unwrapped; keeps metatables (so json
  array marks), copies shared and cyclic tables once, walks without recursion.

## How a user reaches it

```lua
local neon = Neon.new{ api_key = distilled.secret(os.getenv("NEON_API_KEY")) }
print(err)            -- never shows the key
```

## Driving it with `dl`

- `verify/dl test secret` runs `spec/secret_spec.lua`, which checks a canary value never
  appears through `tostring`, concatenation, `pairs`, the harness dumper or a `json.encode`
  error. `dl canary` (plan step 6) will grep whole runs for a fake key.

## Gotchas

- The value is stored in the wrapper's own metatable (`__secret_value`), not a field, so
  `pairs`, `next` and table dumpers see an empty table. `getmetatable(s).__secret_value`
  still reaches it: this guards against accidents, not against hostile code.
- `json.encode` refuses a secret (it looks for `__distilled_secret` in the metatable)
  instead of writing `{}`. Unwrap at the point of use.
- Secrets are read-only (`s.x = 1` raises) and compare by identity: two wraps of the same
  string are different values.
- `string.format("%s", s)` calls `tostring` on 5.2+ but raises on 5.1/luajit; use
  `tostring(s)`.
