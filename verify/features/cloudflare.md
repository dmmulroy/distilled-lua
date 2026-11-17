# Cloudflare (`clients/cloudflare`, `distilled.protocol.cloudflare`)

Task 19. A port of Distilled's `packages/cloudflare` (`src/protocol.ts`, `credentials.ts`,
`errors.ts`, `pagination.ts`, `retry.ts`, `jurisdiction.ts` and the SdkSpec in
`scripts/generate.ts`) for the 130 Cloudflare models (129 v4 services plus the
hand-written `k2`), 3,128 operations, plus 25 opAlias methods (3,153 methods).

## Sub-features

- **Generation** (`lua/distilled/gen/cloudflare.lua`, applied when the service has
  `com.cloudflare.protocols#v4Json` or the provider spec names the protocol):
  - The Cloudflare traits are rewritten into generic vocabulary: `nullable`,
    `errorMatchers`, `envelopePayload` (to an `httpPayload`, or `rawResponse` when it is
    the only member), `binaryResponseBody` (a Blob payload), `deepQuery` (`style = "deep"`
    query), `formDataFile` (`form_file`), `host` (`op.host`) and `jurisdiction`
    (`op.jurisdiction`).
  - `optionalsNullable`, and a `result_info` member (ResultInfo) on paginated outputs.
  - Pagination paths: the model writes them in TS names (`perPage`,
    `resultInfo.page`); they are translated back to wire names.
  - The key dictionary's fallback wire names for top-level output members.
  - Distilled's `validatePaginated`: an unusable trait is dropped with a warning.
  - opAliases (model metadata). `export const <alias> = <target>` in Distilled becomes a
    second method on the same operation, documented as an alias. It is only added when
    the target is generated and the name is free (`gen/cloudflare.lua add_aliases`).
  - A multi-model package: one module per API resource (`require("cloudflare.d1")`), as
    Distilled's one TS module per resource. Large services (zero_trust, radar, rulesets,
    ...) use task 18's split layout.
- **Auth** (credentials.ts). Options are read first:
  - `api_token` is sent as `authorization: Bearer <token>`. An OAuth access token is an
    `api_token` too.
  - `api_key` plus `email` are sent as `x-auth-key` and `x-auth-email`. One without the
    other is a ConfigError.
  - Without options, the same values come from `CLOUDFLARE_API_TOKEN`,
    `CLOUDFLARE_API_KEY` and `CLOUDFLARE_EMAIL`. These are read per request, and an
    empty variable counts as unset.
  - The base URL defaults to `https://api.cloudflare.com/client/v4`. It can be set with
    the `base_url` option or `CLOUDFLARE_API_BASE_URL`.
  - A member-supplied `Authorization` header gets the Bearer prefix. This is
    protocol.ts's quirk for workers' `jwt_token`.
- **Requests**:
  - Labels, query (deep objects as `a.b=`) and header members.
  - Unknown input keys are sent snake_cased.
  - Multipart bodies come from `formDataFile` members: each file is sent as a part
    named after its filename. Other bodies are raw or text.
  - Per-operation hosts. pipelines' `https://{stream_id}.ingest.cloudflare.com` takes its
    label from the input.
  - R2 jurisdiction: the `jurisdiction` client option or per-call input sends the
    `cf-r2-jurisdiction` header.
- **Responses**:
  - Envelope: the payload is `result`; `result_info` is the paginated output's
    `result_info`.
  - A bare-payload output is `result` itself.
  - Binary bodies with typed response headers, and non-JSON bodies.
  - K2's single `error` object.
  - Strict mode rejects envelope keys the output does not model.
- **Errors**, in protocol.ts's order. A failure is status >= 400, or `success: false`
  with any status. Classification then runs:
  1. The operation's typed errors (the model's per-code matchers, specificity first).
     When the envelope has no code, the code is 0.
  2. The global codes:
     - 971 is TooManyRequests.
     - 6003, 9103, 9106 and 9109 are Unauthorized.
     - 10000 is Unauthorized, retryable on "Authentication error".
     - 10001 is Forbidden, retryable on "internal error" or "unable to authenticate
       request".
     - 7003 is InvalidRoute.
     - 1000 is GatewayTimeout on a timeout, InternalServerError on "internal server",
       and UnknownCloudflareError otherwise.
  3. Throttling: a 429, or the rate-limit message under any status.
  4. Status classes: a mapped 4xx, or any 5xx.
  5. `UnknownCloudflareError` with code, status and body.

  Bodies that cannot be parsed raise `CloudflareParseError`. Transient authentication
  blips are marked retryable on every path. Retry is core's default policy (Distilled's
  `Retry` tag maps to the client's `retry` option).
- **Response validation**: every Cloudflare union is checked as `unknown`, as in
  Distilled. Its unionStyle `opaque-cases` emits `S.Unknown.pipe(T.UnionCases(...))`,
  and Cloudflare returns every case's keys, with null for the inactive ones. Decoding
  still picks an arm.
- **Pagination** (`paginate.lua` `strategies["cloudflare.page"]`, pagination.ts):
  - Page mode sends `page` (and `per_page` if given). It stops on an empty page or when
    `page >= total_pages`. It also stops on a page short of `per_page` once the items
    seen reach `total_count`; a short page alone is not trusted. A server that ignores
    `page` (it reports another page than the one asked for) ends the traversal without
    the duplicate page.
  - Cursor mode reads `result_info.cursor` or `result_info.cursors.after`.

## How a user reaches it

```lua
local D1 = require("cloudflare.d1")
local d1 = D1.new({ api_token = token, host = require("distilled.host.popen")() })
local dbs, err = d1:list_databases_items({ account_id = id }):collect()
local db, err = d1:get_database({ account_id = id, database_id = "x" })
if err and err.tag == "DatabaseNotFound" then ... end
local R2 = require("cloudflare.r2")
local r2 = R2.new({ jurisdiction = "eu" })   -- CLOUDFLARE_API_TOKEN from the environment
```

Each model's `README.md` lists its options and operations.

## Driving it with `dl`

- `verify/dl test cloudflare` runs three specs:
  - `cloudflare_protocol_spec` ports protocol.test.ts: envelope, error order, global
    codes, blips, auth modes and env, Bearer prefix, multipart, host, jurisdiction,
    binary and K2.
  - `cloudflare_pagination_spec` ports pagination.test.ts, plus cursor and stop cases.
  - `cloudflare_conform_spec` is the conformance replay below.
- `verify/dl gen-diff cloudflare`:
  - The generation is identical under lua and luajit, and matches the committed
    `clients/cloudflare`.
  - stylua passes.
  - gen-check passes under Lua 5.5, luajit and rex. All 130 services load, every ref
    resolves and 3153/3153 requests build.
- Conformance against Distilled's TS SDK (`verify/conform/cloudflare/`):
  - `lua verify/conform/cloudflare/cases.lua .` writes `cases.jsonl`: up to 5 operations
    per model, with special operations first (host, jurisdiction, deep query, headers,
    payloads, each pagination mode).
  - Each operation gets a request case, an envelope success, a success with nulls under
    strict validation, a typed error from its first matcher, an unknown code, and one
    rotating failure (global codes, 429, a non-JSON 502, an empty 404, ...). Paginated
    operations also get a flow.
  - `node --conditions=bun --experimental-transform-types --no-warnings
    verify/conform/cloudflare/ts.mjs` answers every case with Distilled's TS SDK
    (scripted HttpClient, no network) into `ref.jsonl`.
  - `lua verify/conform/cloudflare/run.lua .` compares (any runtime; `MAX=n` sets how
    many mismatches it shows). Today the result is 3,090 cases over 536 operations of
    130 models, with 0 mismatches and one intended difference (below).

## Gotchas

- Lua member names are the wire names (snake_case). Distilled camelCases them. The
  comparison maps Lua values to TS names (`lib.to_ts`) by the schema, plus Distilled's
  key-dictionary renaming of opaque content and union cases. Distilled keeps only the
  active case's keys of a union. Lua keeps every key the API sends, which is core's rule
  for undeclared keys.
- Intended difference: Distilled's `CloudflareParseError` has no message (only body and
  cause). Lua's message names the operation and the mismatch. The comparison checks the
  cause's path and expectation instead.
- `CloudflareParseError` and `UnknownCloudflareError` are the provider's
  `parse_tag`/`unknown_tag`. `InvalidRoute` is defined by the protocol, and models
  declare their own with the same tag.
- gopher-lua: the validation view of the registry (unions as `unknown`) is built lazily
  and cached per node. Registries are long-lived, so the cache is bounded even where weak
  tables are never collected.
- Before task 18's split layout, luajit refused `zero_trust/service.lua` (more than
  65,536 constants). It now loads under all three runtimes.
