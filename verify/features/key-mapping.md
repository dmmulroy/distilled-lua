# Key mapping (`distilled.keys`)

## Sub-features

- `keys.encode(node, value, registry)` / `keys.decode(...)`: user <-> wire names by
  walking value and schema together (port of `mapKeys`). Undeclared keys pass through;
  a declared member wins over a colliding undeclared key.
- Array-ness: tables at list nodes come back `json.array` (empty lists encode as `[]`),
  tables at map/struct nodes `json.object`.
- Unions: `schema.pick_arm` (array -> first list arm; discriminator tag; best-explaining
  struct arm: covered minus unexplained non-null keys, ties by coverage then order).
- `string_encoded` (encode only, element-wise, null stays null), `keys.string_encode`.
- `keys.verbatim(node, registry, direction)` (`mapsVerbatim`), cached per registry and
  node: a verbatim encode marks tables in place and does not copy; a verbatim decode
  returns the value untouched.

## How a user reaches it

Indirectly: `request.build` encodes body members, the protocol (task 04) decodes
responses. Only matters when a provider spec renames fields.

## Driving it with `dl`

- `verify/dl test keys` runs `spec/keys_spec.lua`: renaming, marks, verbatim, unions
  (ported from the UnionCases tests in `protocol-http.test.ts`), 600-deep recursive data
  in all three runtimes, cycles.

## Gotchas

- No recursion over data (gopher-lua's ~250 frames): explicit stack; values deeper than
  `json.MAX_DEPTH` are left as they are (a cycle then fails in `json.encode`).
- Distilled's `KeyDictionary` and `UnionCases` member dictionaries are not in the node
  contract, so opaque content is never renamed, and a union does not drop the keys of
  inactive arms on decode (Distilled's merged-case unions do).
- The discriminator key is looked up as given (wire and user names are the same for
  every discriminator in the patches).
