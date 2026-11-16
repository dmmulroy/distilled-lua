# JSON codec (`distilled.json`)

## Sub-features

- Decode: objects, arrays, strings (all escapes, `\uXXXX` to UTF-8, surrogate pairs, lone
  surrogates to U+FFFD), numbers (strict JSON grammar), `true`/`false`/`null`.
- `json.null` sentinel for null in both directions, including inside arrays.
- Array marks (`json.array`, `json.is_array`) and object marks (`json.object`,
  `json.is_object`); decoded arrays are marked, so `[]` and `{}` survive a round trip.
- Encode: sorted object keys, JSON.stringify number formatting (shortest round-trip
  digits, exponent outside 1e-7..1e21), JSON.stringify string escaping, `-0` as `0`,
  optional two-space indent.
- Failure: decode errors are `ParseError` with `err.position` (byte offset) and line and
  column in the message; encode errors are `InvalidInput` (NaN, infinity, cycle, function,
  secret, bad key, array with non-index key, nesting deeper than `json.MAX_DEPTH` = 1000).
- No recursion either way (explicit stacks), linear-time output (table + `compat.concat`).

## How a user reaches it

```lua
local json = require("distilled.json")
local v, err = json.decode(text)           -- err.tag == "ParseError", err.position
local s, err = json.encode(v, { indent = true })
json.null, json.array({}), json.object({}), json.is_array(t)
```

`distilled.null` is the same sentinel.

## Driving it with `dl`

- `verify/dl test json` runs `spec/json_spec.lua` under lua, luajit and rex: every escape,
  surrogates, nesting limits, numbers, 38 invalid inputs with positions, the 862 KB Neon
  model round trip.
- `verify/dl test --json-fuzz` generates seeded random documents in Node
  (`verify/lib/json_gen.mjs`), round-trips them through our codec under each runtime
  (`verify/lib/json_diff.lua`) and compares byte for byte with `JSON.parse` +
  `JSON.stringify` (keys sorted). `DL_FUZZ_SEED` and `DL_FUZZ_COUNT` vary the run; a
  difference prints the first diverging lines.
- `verify/dl json-bench [file]` times decode and encode under each runtime.

## Gotchas

- An unmarked empty table encodes as `{}`. Mark it with `json.array` when the wire wants
  `[]`; `keys.encode` does this from the schema.
- A table with keys `1..n` and nothing else is an array; any other key (or a hole) makes
  it an object with string keys. Marks win.
- Integers beyond 2^53 lose precision on luajit and gopher-lua (float64). On 5.5 they stay
  exact integers. Models should carry 64-bit ids as strings.
- On 5.5, decoded integral numbers below 2^53 are integer-subtype (so `tostring` prints
  `10`, not `10.0`), including `1.0` and `1e3`. `-0` stays a float negative zero.
- Lone surrogates cannot be UTF-8; they decode to U+FFFD (Go does the same), so such a
  string does not round-trip exactly. JSON.parse keeps them.
- Out-of-range numbers decode to `±1/0` (or `0`), like JSON.parse, but encoding an
  infinity fails (JSON.stringify writes `null`).
- A UTF-8 BOM before the document is rejected, like JSON.parse.
- gopher-lua quirks the codec works around: `tonumber` rejects exponent forms without a
  `.` and huge digit strings; `math.huge` is not infinity; `table.concat` overflows past
  ~2,500 items; the call stack is ~250 frames.
- Arrays are marked with a metatable. A table that already has a metatable is marked in a
  weak registry instead, which gopher-lua never collects.
