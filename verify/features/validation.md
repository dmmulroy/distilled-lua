# Response validation (`distilled.validate`)

## Sub-features

- `validate.check(node, value, registry, { exact })` -> `true | nil, { path, expected,
  actual, missing, message }`: port of `response-validation-strict.ts`.
- `exact = false` is Distilled's `additionalProperties`; `exact = true` is `strict`
  (undeclared keys rejected, except in `open` structs and empty structs).
- `json.null` satisfies only nullable members (or `null`/`unknown` ones); required
  members must be present; empty structs accept anything but null; enums are open unless
  exact; unions accept any arm.
- `validate.withhold(mismatch)` replaces the value found by `"[REDACTED]"`.

## How a user reaches it

`validation = "additional" | "strict"` on a client (task 04); `lenient` (default) does
not call it.

## Driving it with `dl`

- `verify/dl test validate` runs `spec/validate_spec.lua`: the exact-mode, path and
  recursive cases of `response-validation-strict.test.ts`, the checker half of
  `response-validation.test.ts`, 700-deep values.

## Gotchas

- Paths use Lua's 1-based list indices (`["items",2,"id"]` where Distilled says 1).
- The first mismatch follows declaration order, then undeclared keys and map keys in
  sorted order (Lua tables have no insertion order).
- Only unions nest a sub-check; more than `validate.MAX_UNION_DEPTH` (64) unions deep in
  the data fails with a clear mismatch instead of overflowing the stack.
- Messages quote up to 40 characters of the value found; use `withhold` when the output
  can hold a secret.
