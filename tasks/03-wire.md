# Task 03: schemas and the wire algorithms

You build layer 2: the schema node helpers and the pure functions that turn an operation and
an input into an HTTP request, and a response body back into a value. No network, no client
yet. Task 01 is finished; build on it. Task 02 (tracing) runs at the same time as you in this
working tree, so stay inside your files.

Read `AGENTS.md`, then `docs/interfaces.md` ("Schema nodes", "Operation and service
descriptors", "Algorithms"), then sections 4.2-4.5 and 4.8-4.9 of `../distilled-deep-dive.md`.

The reference implementation is `../distilled/packages/core/src/`: `protocol-http.ts`
(`buildRequest`, `mapKeys`, `invalidLabel`, `appendQuery`, `flattenToFormPairs`,
`encodeGreedyLabel`, response header members), `sensitive.ts`, `plain-values.ts`,
`response-validation-strict.ts`, `trait.ts`. Port behaviour, including what the comments say
about why. Port the cases in `../distilled/packages/core/test/protocol-http.test.ts`,
`protocol-rest.test.ts`, `sensitive.test.ts`, `response-validation*.test.ts` that apply.

## Files you own

```text
lua/distilled/schema.lua     constructors, resolve, walk helpers, per-struct plan cache
lua/distilled/url.lua        percent-encoding, query building, URI templates
lua/distilled/request.lua    request.build
lua/distilled/keys.lua       keys.encode / keys.decode
lua/distilled/redact.lua     redact.wrap, redact.holds_sensitive, redact.plain
lua/distilled/validate.lua   validate.check
lua/distilled/regex.lua      a small regular-expression matcher (see below)
lua/distilled/errors.lua     ONLY the text-matcher part of errors.match (see below)
lua/distilled/testing/       scripted transport, fake clock/host, fixtures helpers
spec/{schema,url,request,keys,redact,validate,regex,testing}_spec.lua
verify/features/{request-building,key-mapping,redaction,validation}.md
STATUS.md (your section)
```

## Requirements

1. **`schema.lua`**: constructors that return the plain node tables in the contract
   (`S.string`, `S.list(item)`, `S.struct{ name=, members=, open= }`, `S.ref(name)`, ...),
   `schema.resolve(node, registry)` (follows refs, fails with `SdkError` on a missing name),
   and a cached per-struct plan (members grouped by binding) keyed weakly on the node, like
   Distilled's `planFor`.
2. **`url.lua`**: RFC 3986 percent-encoding identical to JavaScript's `encodeURIComponent`
   for all byte values (test all 256), greedy label encoding, query string assembly in
   insertion order.
3. **`request.build`**: everything `buildRequest` does that applies to JSON, form-urlencoded
   and raw bodies:
   - labels (refuse `.` and `..` with `InvalidInput` before anything else; greedy `{name+}`),
   - query (scalars, repeated arrays, nested objects dotted, `comma` and `deep` styles),
   - headers (lowercased), body members under wire names, `payload` (whole body: JSON,
     string, or bytes), `string_encoded`,
   - input keys the schema does not declare pass through as body fields,
   - `{}` body rule for bodied non-DELETE methods, GET bodies only when members carry values,
   - `content-type` set for JSON and form bodies; a member bound to the `content-type`
     header wins,
   - secrets in the input are unwrapped at the last moment (`secret.unwrap_deep`),
   - `json.null` in the input is sent as `null`; an absent key is omitted.
   Multipart is out of scope: return `SdkError` naming the operation.
   The returned request holds the body as a string, already encoded.
4. **`keys.encode` / `keys.decode`**: rename between user names and wire names by walking
   value and schema together, like `mapKeys`, including union arm selection (discriminator
   first, then best-explaining arm). They also fix array-ness: a table at a `list` node is
   marked `json.array` on encode even when empty, and a `map`/`struct` node is marked
   `json.object`. When no member in a subtree is renamed, skip the walk except for the
   array marking (`mapsVerbatim`).
5. **`redact`**: `wrap` turns sensitive members (strings, or any non-null value of an
   `unknown` node) into secrets, through lists, maps, structs and union arms;
   `holds_sensitive` is cached per node; `plain(node, text)` returns `"[REDACTED]"` when the
   node can hold a secret.
6. **`validate.check`**: the lenient/additional/strict rules of
   `response-validation-strict.ts`. `exact = true` rejects undeclared keys except in open
   structs and empty structs. `json.null` satisfies only nullable members. Returns the path
   to the first mismatch.
7. **`regex.lua`**: patches carry JavaScript regular expressions in error matchers (38 in
   Distilled today; run `grep -rho '"matches": *"[^"]*"' ../distilled/packages/*/patches`
   to see them). Lua patterns cannot express alternation or groups, so write a small
   backtracking matcher: literals, `.`, character classes and negated classes with ranges,
   `\d \w \s \D \W \S`, escapes, `* + ?` and lazy forms, `{m,n}`, groups (capturing and
   `(?:`), alternation, `^` `$`. `regex.compile(source) -> matcher | nil, err`;
   `matcher:test(text) -> boolean` (unanchored search, as JavaScript's `RegExp.test`).
   Unsupported syntax (lookaround, backreferences, flags, Unicode classes) must fail to
   compile with a clear message, never match wrongly. Every one of the 38 patterns must
   compile and behave as in Node; add a differential check against `node -e` for a table of
   pattern and text pairs.
   Then update the text-matcher code path in `errors.match` so a matcher's `matches` (the
   regex source string, as the model carries it) is compiled once and cached. The contract
   in `docs/interfaces.md` has been updated to say this.
8. **`testing/`** (used by every later task):
   - `testing.transport{ responses }`: returns responses in order (a response may be a
     table, an error, or a function of the request), records every request in `.requests`,
     and fails loudly when it runs out.
   - `testing.host{ now = 0, seed = 1 }`: a host table with a fake clock (`sleep` advances
     `now` and appends to `.sleeps`), a seeded deterministic `random`, `epoch`, a `getenv`
     over a table, and the scripted transport.
   - A helper that builds a small fake service (two or three operations with labels, query,
     body, a paginated one, an error with matchers, a sensitive output member) for specs, in
     `lua/distilled/testing/fixtures.lua`. Shape it like the real model: look at
     `models/neon.json` (the patched Smithy model for Neon) for realistic operations.

## Done means

- `verify/dl doctor` clean, `verify/dl test` green in all three runtimes, including your specs.
- `tasks/03-wire.done.md` committed with the command output, the list of Distilled test
  cases you ported, and anything in `buildRequest`/`mapKeys` you chose not to port and why.
