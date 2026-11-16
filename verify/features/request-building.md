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
- Multipart (`op.content_type = "multipart"`, task 08): an RFC 7578 body string from
  `distilled.multipart`; see "Multipart bodies" below.

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

## Multipart bodies (task 08)

`op.content_type = "multipart"` builds a `multipart/form-data` body as a string
(`lua/distilled/multipart.lua`), following the multipart branch of Distilled's
`buildRequest` and the bytes undici writes for a `FormData` (checked against Node 24).

- A file value: `distilled.file{ data = "<bytes>", filename = "a.zip",
  content_type = "application/zip" }` (filename and content_type optional; data may be a
  secret; the same function as `require("distilled.multipart").file`).
  `multipart.is_file(v)` tells it from an ordinary table.
- Each body member is a part under its wire name, in declaration order, undeclared keys
  after (sorted). A file is a file part with its own filename, or the wire name when it
  has none (Distilled's nameless Blob), and its content type, else
  `application/octet-stream`. A string at a `blob` node is a file part named after the
  member (Distilled's Uint8Array). A non-empty list whose elements are all binary is one
  part per element under the same name. Other tables are one JSON part (`[]` for an empty
  list); scalars are text (`String(v)`); `json.null` and absent members are omitted.
- A `payload` member holding a record is the parts instead, one per entry, in **sorted**
  key order (JavaScript keeps insertion order; a Lua table has none). A `payload` holding
  one file (or a string at a blob payload) is one file part under the wire name.
- Names: line breaks normalized to CRLF, then `"`, CR, LF escaped as `%22`, `%0D`, `%0A`;
  filenames: the same escapes without the normalization. Text values: line breaks become
  CRLF (undici does this). File data is byte for byte (NUL, CRLF, 0xFF).
- Boundary: `----distilled-lua-` + 24 alphanumerics from `random` (`args.random` or
  `args.host.random`; without either, `distilled.host`'s private generator). It is drawn
  again (up to 16 times) while it occurs in any part; then `SdkError`. With the testing
  host's seeded random the body is deterministic, so specs compare whole bodies.
- The multipart body is sent for any method, GET included, as Distilled does.
- Generated types: a Blob member of a multipart input is `distilled.File|string`.

Driving it: `verify/dl test multipart` (`spec/multipart_spec.lua`): the encoder, the
ported `protocol-http.test.ts` cases ("multipart binary parts", "multipart file lists"),
and a differential against Node's `Request.formData()` (via io.popen under lua/luajit and
rex.exec under gopher-lua; pending when node is missing) that checks names, filenames,
content types and every byte value. `verify/dl gen-diff neon` builds all 178 operations.

Gotchas:

- Through a generated client the boundary comes from the client's `host.random` (the REST
  protocol passes `host = ctx.host` to `request.build`, task 09), so it is deterministic
  under `testing.host` (`spec/neon_client_spec.lua` checks it).
- Distilled's `FormDataFile()` binding (files appended under their own filename) has no
  Smithy trait in the models, so there is no such bind.
- A file nested inside a JSON part is JSON-encoded as a table with its fields (Distilled
  would write `{}` for a File): files belong at the top level of the form.
