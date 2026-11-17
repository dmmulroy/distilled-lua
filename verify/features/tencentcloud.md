# Tencent Cloud (`clients/tencentcloud`, `distilled.protocol.tencentcloud`)

Tencent Cloud API 3.0: 263 products (one model each), 15,381 operations, the same count
as Distilled's `@distilled.cloud/tencentcloud` (`API.make` in `src/services/*.ts`).

## Sub-features

- **TC3-HMAC-SHA256** (`lua/distilled/tencentcloud/signer.lua`, port of `signer.ts`):
  canonical request, string to sign, `TC3<key>` / date / service / `tc3_request` key
  derivation, the UTC date of the timestamp (no `os.date`), signed headers
  deduplicated and sorted (default `content-type;host;x-tc-action`, as Tencent's SDKs).
- **Protocol** (`lua/distilled/protocol/tencentcloud.lua`, port of `protocol.ts`,
  `credentials.ts`, `region.ts`): `POST https://<service>.<root_domain>/`, the input as
  the JSON body (always an object, `{}` when empty), `X-TC-Action`, `X-TC-Version`,
  `X-TC-Timestamp` (host epoch, floored), `X-TC-Region`, `X-TC-Token`, `Authorization`,
  `Content-Type: application/json; charset=utf-8`. Every retry is signed again.
- **Region**: the input's `region` member (bound to `X-TC-Region` in every model) >
  the client option `region` (`client:with{ region = ... }` plays Distilled's `Region`
  layer) > `TENCENTCLOUD_REGION` > no header (CAM, DNSPod, SSL, Tag, ...).
- **Credentials**: client options `secret_id` (`TENCENTCLOUD_SECRET_ID`, required),
  `secret_key` (secret, `TENCENTCLOUD_SECRET_KEY`, required), `session_token` (secret,
  `TENCENTCLOUD_SESSION_TOKEN`), `root_domain` (default `tencentcloudapi.com`), plus
  `endpoint` (ours: a URL replacing `https://<service>.<root_domain>`, `{service}`
  filled in; the signed host is its host). Distilled has no profile/file credentials,
  so neither do we (a `secret_key = fn(host)` source covers files and commands).
- **Envelope and errors** (`lua/distilled/tencentcloud/errors.lua`, port of
  `errors.ts`): `{ Response: { Error: { Code, Message }, RequestId } }` at any HTTP
  status fails the call; the code's first segment picks one of the 27 common classes
  (`ResourceNotFound.InstanceNotExist` -> `ResourceNotFound`, `code` keeps the full
  value, `request_id` the RequestId), `ServiceUnavailable` is the core class, anything
  else `UnknownTencentCloudError` (with `status`, `body`). Categories and retryability
  as Distilled: `InternalError` (ServerError, retryable), `RequestLimitExceeded`
  (ThrottlingError, retryable throttling), `AuthFailure`/`UnauthorizedOperation`/
  `IpInBlacklist`/`IpNotInWhitelist` (AuthError), `LimitExceeded`/`ResourceInsufficient`
  (QuotaError), `ResourceInUse`/`ResourceUnavailable` (ConflictError), the rest
  BadRequestError or none. No envelope: the core status map (5xx unmapped ->
  InternalServerError, Retry-After honoured), else `UnknownTencentCloudError`; a 2xx
  without it is `TencentCloudParseError`. The Response object is the output
  (`RequestId` included), validated per the client's `validation` mode.
- **Pagination**: none, as in Distilled (it generates no paginated operation; `Offset`
  / `Limit` and `TotalCount` are plain members the caller drives).
- **Generator: RPC models** (`lua/distilled/gen/rpc.lua`, provider spec key `rpc`):
  operations without `smithy.api#http` get one binding (`POST /`), the operation trait
  (`com.tencentcloud#action`) is copied to `op.rpc = { service, version, action }`,
  checked at generation (required string fields, plain names), and the client's
  `init.lua`, README and `types.lua` options come from the protocol module
  (`.options`, `.option_docs`). No `base_url` needed. Hooks: `gen/provider.lua`
  (validation), `gen/ops.lua` (`ops.http` fallback, descriptor field),
  `gen/writer.lua` (client and README), `gen/types.lua` (options), `gen/traits.lua`.
  The same key fits other RPC protocols (AWS JSON/query) with their own module.

## How a user reaches it

```lua
local tencentcloud = require("tencentcloud")          -- the index: 263 products
local Cvm = tencentcloud.cvm                          -- = require("tencentcloud.cvm")
local cvm = Cvm.new({ host = require("distilled.host.popen")() }) -- keys from the env
local out, err = cvm:describe_instances({ region = "ap-guangzhou", Limit = 10 })
if err and err.tag == "ResourceNotFound" then ... end -- err.code, err.request_id

local clients = tencentcloud.new({ secret_id = id, secret_key = distilled.secret(key),
                                   region = "ap-singapore" })
clients.vpc:describe_vpcs({})
```

## Driving it with `dl`

```sh
verify/dl models sync tencentcloud      # models/tencentcloud/*.json from ../distilled
verify/dl gen-all tencentcloud          # regenerate clients/tencentcloud (12 s)
verify/dl gen-diff tencentcloud         # regenerate + compare, load and build every op in
                                        # lua, luajit, rex; rpc ops are also signed through
                                        # the client's protocol (about 3 min)
verify/dl test tencentcloud             # specs below, three runtimes
verify/dl test --http tencentcloud      # + a signed call over HTTP against dl serve
verify/dl tencentcloud-ref              # rerun Distilled (Node) -> spec/golden/tencentcloud/ref.json
```

Specs: `spec/tencentcloud_conform_spec.lua` (Distilled's output, byte for byte: 16
signer vectors incl. the documented example, cross-checked in Node against
`node:crypto`; 17 requests over 10 products: URL, Authorization, X-TC-*, body; 85
response outcomes: every common code, envelope oddities, status fallbacks, validation),
`spec/tencentcloud_protocol_spec.lua` (ports of `protocol.test.ts`, env credentials,
region order, endpoints, retries, secrets, spans, HTTP), `spec/tencentcloud_gen_spec.lua`
(the `rpc` spec key, generation failures, the committed index).

## Intended differences (normalised in `spec/tencentcloud_conform_spec.lua`)

| Difference | Lua | Distilled | Why |
| --- | --- | --- | --- |
| Body key order | sorted (distilled.json) | the caller's insertion order | Lua tables have no order; the signature covers our bytes, so it is valid either way. The reference uses sorted inputs, so bodies and signatures are byte-equal |
| `err.status` | always the HTTP status | absent on envelope classes | as Neon: every HTTP error has `status` |
| ServiceUnavailable from an envelope | keeps `code` and `request_id` | message only | keep what the server said |
| Parse error message | says what failed | `""` | as Neon |
| `endpoint` option | exists | no equivalent | proxies and the local fixture server |

## Gotchas

- `secret_id` is a plain option (it is in every Authorization header); `secret_key`
  and `session_token` are secrets and only unwrapped inside the signer / header build.
- Message truncation of a non-JSON error page (500) and body (2,000) count bytes, not
  UTF-16 units.
- Output size: 44 MB of generated Lua for 263 products (csip, the largest, is 1.2 MB of
  service.lua; `require` takes 15 ms in lua/luajit, about 0.4 s in Rex). Task 18 owns
  emission size; nothing here depends on the layout.
