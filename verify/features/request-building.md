# Request building (`distilled.request`, `distilled.url`, `distilled.schema`)

## Sub-features

- `request.build{ op, input, registry, base_url, headers, map_member_header,
  unknown_key_to_wire, empty_json_body, query_style }` -> `{ method, url, headers, body }`
  or `nil, err` (`InvalidInput`, `SdkError`). Port of Distilled's `buildRequest`.
- Labels: `.`/`..` refused first (greedy: any segment), missing labels refused,
  encodeURIComponent escaping, greedy `{name+}` per segment (`url.encode_greedy_label`).
- Query: insertion order, lists repeat the name, nested tables dotted (sorted keys),
  `style = "comma"`, `style = "deep"` (renamed, nulls skipped), `query_style = "brackets"`.
  Encoded like URLSearchParams (`url.encode_form`: space is `+`, `~` is `%7E`).
- Headers lowercased, `String(v)`, CR/LF refused, `map_member_header`.
- Body: wire names (`keys.encode`), `string_encoded`, undeclared keys pass through,
  `payload` (JSON, or raw bytes for `blob` / `op.body_media_type`), form-urlencoded with
  bracket notation, the `{}` rule, GET bodies only when set, `content-type` member wins.
- Secrets unwrapped on a copy at build time; `json.null` sent as `null`.
- `schema.plan(struct)`: members grouped by binding, cached per node.
- Multipart: `SdkError` naming the operation.

## How a user reaches it

Through a client call (task 04's protocol calls `request.build`). Directly:

```lua
local req, err = request.build{ op = service.ops.get_project, input = { project_id = "p1" },
  registry = service.shapes, base_url = "https://console.neon.tech/api/v2",
  headers = { authorization = secret.wrap("Bearer ...") } }
```

## Driving it with `dl`

- `verify/dl test request` runs `spec/request_spec.lua`: the cases ported from
  `protocol-http.test.ts` (StringEncoded, empty bodies, label encoding, greedy labels,
  dot-segment labels) and `protocol-rest.test.ts` (request encoding, raw bodies), plus the
  fixture service's operations.
- `verify/dl test url` runs `spec/url_spec.lua`: every byte 0-255 against values recorded
  from Node's `encodeURIComponent` and `URLSearchParams`, UTF-8 text, `String(number)`.
- `verify/dl test schema` runs `spec/schema_spec.lua`: constructors, `resolve`, `plan`.

## Gotchas

- `secret.unwrap_deep` turns `json.null` into a fresh `{}` (it copies it like any table),
  so `request.build` uses its own unwrap that keeps `json.null`.
- Lua tables have no insertion order: nested query objects and form bodies use sorted
  keys; top-level members keep declaration order, then undeclared keys sorted.
- `json.null` in a query or label is sent as the text `null`, like Distilled's
  `String(null)`. A string `payload` without `blob` or `body_media_type` is sent as a
  JSON string (`"text"`), also like Distilled.
- Indices in form bodies are 0-based (`a[0]`), as in JavaScript.
