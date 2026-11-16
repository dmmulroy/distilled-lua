# Errors and typed matching (`distilled.errors`)

## Sub-features

- Classes: `errors.define{ tag, categories, retryable, throttling, matchers, fields }`.
- Instances: `errors.new(class_or_tag, fields)` with `tag`, `message`, `categories` (a set),
  `retryable`, `throttling`, `status`, `code`, `body`, `headers`, `retry_after`,
  `trace_id`, `cause`; `tostring(err)` is `"Tag: message"` plus `" [trace <id>]"`.
- Predicates: `is`, `is_class`, `is_tag`, `has_category`, `is_transient` (Distilled's
  `isTransientError`), `is_throttling` (`isThrottling`).
- Built-in classes from `core/src/errors.ts` (`errors.classes.NotFound`, also
  `errors.NotFound`), `STATUS_MAP` (HTTP_STATUS_MAP), `RETRYABLE_STATUSES`,
  `DEFAULT_STATUSES`, the sixteen `CATEGORIES`.
- Typed matching: `errors.match(classes, response_info)` is `matchTypedError`: all
  constraints of a matcher must hold, the most specific matcher wins, ties go to the first
  declared class; declared fields are filled from the body (at `fields_at`, then top level).
- Helpers exposed for tests and later layers: `errors.at_pointer` (RFC 6901),
  `errors.matches_expression`, `errors.matcher_specificity`.

## How a user reaches it

```lua
local res, err = neon:get_project{ project_id = "p1" }
if err then
  if err.tag == "NotFound" then ... end
  if err.categories.AuthError then ... end
  if errors.is_transient(err) then ... end
end
```

Protocols call `errors.match(op_classes, { status, code, message, body, headers,
fields_at, retry_after })` and fall back to `errors.STATUS_MAP`.

## Driving it with `dl`

- `verify/dl test errors` runs `spec/errors_spec.lua`: the class/predicate rules from
  `category.ts`, every built-in's categories and retry marks, and the matcher cases ported
  from `protocol-rest.test.ts` (status + message, numeric code, specificity, string code vs
  numeric matcher, case-insensitive header names, body pointers, declared fields,
  `fields_at`, `retry_after`, text bodies), plus pointer edge cases (`json.null`, indices,
  `~0`/`~1`).

## Gotchas

- Text matchers are `"exact"` or `{ includes = "...", matches = "<JS regex>" }`. `matches`
  is tested with `distilled.regex` (the JavaScript subset the patches use), compiled once
  per source through the `regex_test` hook in `errors.lua`; a source that does not compile
  never matches (the generator refuses such patterns). `spec/rest_spec.lua` covers a regex
  matcher picking the class through a whole call.
- A matched error's `code` is the wire error's code or `nil`. Distilled uses `0` when the
  envelope had no numeric code.
- `status` is always the HTTP status, and `code`, `message`, `body`, `headers`,
  `retry_after` and the other instance fields are reserved: a class field with one of those
  names is not copied from the body (Distilled's `Nested.status` would be the body's
  string; here it is the HTTP status).
- `retry_after` is not parsed here (that is `retry.parse_retry_after`); the caller passes
  seconds in `response_info.retry_after`, and only classes that declare the `retry_after`
  field (the retryable built-ins, or a class listing it) receive it.
- A missing body member never matches, not even a `json.null` matcher; a present null
  matches only `json.null`, never a text matcher. Code comparison is type-strict: `"4001"`
  is not `4001`.
- An unconstrained matcher (`{}`, or empty `body`/`headers`) matches nothing.
