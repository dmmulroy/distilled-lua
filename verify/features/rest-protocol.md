# REST protocol (`distilled.protocol.rest`)

## Sub-features

- `rest.new{ base_url, headers, error_envelope, error_fields_at, status_map,
  classify_error, unknown_tag, parse_tag, unknown_error, parse_error,
  transform_response, map_member_header, unknown_key_to_wire, empty_json_body,
  query_style, user_agent }` -> `protocol` with `call(ctx, op, input)`,
  `encode(ctx, op, input, creds)` (no send) and `decode(ctx, op, response)`.
  `rest.bearer(option)`, `rest.header(name, option)` build auth headers.
- Request: credentials, base URL (`fn(creds, { uri, method, server })`), auth headers,
  `request.build`, then `traceparent` when the tracer records (unless
  `service.telemetry.propagate == false`), `accept: application/json`, `user-agent`,
  `timeout` (deadline left).
- Failure (status >= 400), Distilled's order: `classify_error`; the operation's declared
  errors by matcher (only number envelope codes take part); the status map
  (`retry_after` only on retryable statuses); unmapped 5xx as retryable
  `InternalServerError`; the unknown error (never retryable). Non-JSON bodies give the
  trimmed text as the message.
- Success: tolerant JSON parse; empty body is `""` for a string output, else `{}`;
  `transform_response`; `keys.decode`; a `payload` member takes the whole body; `header`
  members from response headers (numbers parsed, other text kept); `status` members;
  validation when not lenient (`additional`, `strict`) failing with the parse error;
  `redact.wrap`. `blob` outputs return the bytes. An output that can hold a secret fails
  on a non-JSON body in every mode, and its parse errors carry `"[REDACTED]"`.
- Every call returns `meta = { status, headers }` as a third value when a response came.
- The operation span gets `http.request.method`, `server.address`, `server.port`,
  `http.response.status_code` (the last try wins); debug spans `distilled.credentials`,
  `distilled.request.build`, `distilled.transport`, `distilled.decode`.

## How a user reaches it

Through generated clients (`Client.define{ protocol = rest.new{...} }`); directly:
`protocol.encode(ctx, op, input, creds)` builds the request a call would send.

## Driving it with `dl`

- `verify/dl test rest_spec`: the cases of `protocol-rest.test.ts` (request encoding,
  success decoding, response header members, raw and binary outputs, label refusal,
  typed error matching, error fields, status mapping and fallbacks, envelope and status
  map options), plus callback raises, the fixture regex matcher, secret-holding outputs
  with a canary, traceparent and trace ids.

## Gotchas

- A matched error keeps the wire's string code in `err.code` (Distilled: `0`).
- A class's typed error body (`TypedBody` in Distilled) is not mapped: error classes have
  no body schema here.
- A callback that raises an error table fails the call with that table; any other raise
  is `SdkError`.
- A transport that raises is a bug and propagates (the scripted transport raises when it
  runs out); a transport failure must be `nil, err`.
