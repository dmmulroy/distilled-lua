# Redaction (`distilled.redact`)

## Sub-features

- `redact.wrap(node, value, registry)`: sensitive strings, and any non-null value of an
  `unknown` node, become secrets; through structs, lists, maps, refs and union arms (every
  arm applies; a map arm skips keys a sibling struct arm names). Idempotent.
- `redact.parsed(node, value, registry)`: for logs, every sensitive value wrapped whole.
- `redact.holds_sensitive(node, registry)`, cached per registry and node (only the root
  of a walk, so cycles answer correctly whichever node is asked first).
- `redact.plain(node, text, registry)` -> `"[REDACTED]"` when the node can hold a secret.
- Sensitivity: `member.sensitive`, or `sensitive = true` on any node (through refs).

## How a user reaches it

Decoded outputs come back with secrets (`tostring` prints `<redacted>`); error bodies of
operations whose output can hold a secret are `"[REDACTED]"` (task 04).

## Driving it with `dl`

- `verify/dl test redact` runs `spec/redact_spec.lua`: `sensitive.test.ts` (holdsSensitive,
  redactPlain, redactParsed) and the sensitive union/untyped cases of
  `protocol-http.test.ts`, plus refs, maps, 500-deep data, the fixture's `create_api_key`.

## Gotchas

- A sensitive number or boolean is not wrapped by `wrap` (Distilled wraps strings and
  untyped values only); `parsed` wraps it.
- A typed sensitive struct is walked, not wrapped whole, by `wrap`.
