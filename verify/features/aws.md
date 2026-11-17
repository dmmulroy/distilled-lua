# AWS clients (`distilled.aws.*`, `gen/aws.lua`, `clients/aws`)

A port of Distilled's AWS package (`packages/aws/src/`: protocols, credential
providers, region, retry categories, customizations, SigV2) and the parts of
`packages/s3/src/` it builds on (`protocol.ts`, `protocols/rest-xml.ts`, the
`rules-engine/`, `util/` codec, headers, timestamps, errors, middleware). The generator
reads the native Smithy models in `models/aws/` (`verify/dl models sync aws`, which also
copies Distilled's `manual-specs/`, SimpleDB). S3 itself is task 25 (`clients/s3`,
`distilled.s3`), on this runtime.

`clients/aws`: 433 services, 19,429 operations. `dl parity` counts 19,631 in Distilled's
`src/services`. Every generated service has Distilled's operation count exactly. The 202
missing operations belong to 7 services AWS retired and removed from its spec mirror
(finspace, finspace-data, iot-events, iot-events-data, panorama, simspaceweaver, tnb);
Distilled still ships their old generated files. 58 of the 19,429 operations (event
streams) are generated and refuse the call with `SdkError`, as the provider spec
acknowledges (`allow_unsupported = { "streaming" }`).

## Sub-features

- **Protocols**, one module each, same interface (`encode`, `read`, `read_error`):
  - `aws/json_protocols.lua`:
    - `awsJson1_0` and `awsJson1_1` (51 and 102 services):
      - requests go to `POST /` with `X-Amz-Target` (`<target>.<Op>`);
      - `x-amzn-query-mode` is set for awsQueryCompatible services (SQS, CloudWatch);
      - the error code comes from `x-amzn-errortype`, then `__type`, then `code`, passed
        through `sanitize_error_code`.
    - `restJson1` (260 services):
      - HTTP bindings and payloads (streaming, blob, string/enum, structure);
      - an explicit `{}` body when body members exist but none is set;
      - customizations: API Gateway's `Accept`, Glacier's `X-Amz-Glacier-Version`;
      - a plain-text error body becomes the message.
  - `aws/query.lua`: `awsQuery` (16) and `ec2Query` (EC2):
    - form bodies: `.member.N` lists (flattened, or `.N` on ec2) and `.entry.N` maps;
    - names from `xmlName` and `ec2QueryName`;
    - the `*Result` wrapper is unwrapped;
    - errors are read from `ErrorResponse/Error` or `Response/Errors/Error`.
  - `aws/rest_xml.lua`: `restXml` (Route 53, CloudFront, S3 Control, and S3 in task 25):
    - `xmlName`, `xmlFlattened`, `xmlAttribute`, `xmlNamespace` (the service default
      included);
    - `s3UnwrappedXmlOutput`;
    - errors fall back to a status-code table, an HTML error page, or `InternalError`
      for 5xx.
  - `aws/http.lua`: the shared HTTP bindings:
    - label encoding (plus `!'()*`) and greedy labels; `InvalidInput` for an empty,
      `.` or `..` label;
    - header lists and http-date lists; `@mediaType` headers in base64;
    - `@httpQueryParams`, with `@httpQuery` winning over a key of the same name; static
      query params from the URI (`?tagging`);
    - prefix headers and the response status.
    - A required member that is missing fails before anything is sent:
      `ParseError Expected a value, got undefined at ["Key"]`.
  - `aws/codec.lua`: values against schema nodes:
    - timestamps in `epoch-seconds`, `date-time` and `http-date`;
    - base64 blobs; sparse lists and maps keep `json.null`; unions are tagged;
    - input failures use Distilled's message, with the value withheld (`"[REDACTED]"`)
      when the shape can hold a secret.
  - Choosing a protocol: the model's first `aws.protocols#*` trait the runtime
    implements. `rpcv2Cbor` is ignored, as in Distilled.
- **The call pipeline** (`aws/protocol.lua`, Distilled's `s3/src/protocol.ts` order):
  1. Fill idempotency tokens (a UUID v4 from `host.random`).
  2. Serialise.
  3. gzip the body for `@requestCompression` when it is 10 KiB or more
     (`aws/gzip.lua`, fixed-Huffman deflate in pure Lua).
  4. `httpChecksum`: Content-MD5, or the requested CRC32/CRC32C/SHA-256/SHA-1.
  5. Resolve the endpoint: the custom endpoint (`endpoint` option or `AWS_ENDPOINT_URL`),
     else the rules. `authSchemes` give the signing region and name; SigV4A fails with
     `SdkError`.
  6. Add the host prefix (`smithy.api#endpoint`, `hostLabel`).
  7. Sign: SigV4 (`distilled.sigv4`) on every attempt, with credentials resolved per
     call. `UNSIGNED-PAYLOAD` applies to unsignedPayload ops and streaming bodies; S3
     Control and Glacier hash the payload.
     - SimpleDB uses SigV2 (`aws/sigv2.lua`, the signature in the form body).
     - CodeCatalyst uses a bearer `token` option.
     - Every other request is signed, `optionalAuth` and `auth: []` operations (STS
       AssumeRoleWithWebIdentity) included, as in Distilled: without credentials they
       fail like the rest.
  8. Propagate the trace: `X-Amzn-Trace-Id` (core `telemetry-xray.ts`); all 432 signed
     services ask for X-Ray.
- **Region**, in this order: `input.region` (unless the operation models a `region`
  member), the `region` option, then the credentials' region (`AWS_REGION`,
  `AWS_DEFAULT_REGION`, the profile). With none, the call fails with `MissingRegion`
  before any request.
- **Endpoint rules** (`aws/endpoint.lua`, `aws/partitions.lua`): an interpreter for
  `smithy.rules#endpointRuleSet` 1.0, with every standard and AWS function (`aws.partition`,
  `aws.parseArn`, `aws.isVirtualHostableS3Bucket`, ...). Each client's rule set is
  `clients/aws/<svc>/endpoints.lua`, JSON in a long string decoded on first use, cached
  per operation and parameters (64 entries). Distilled compiles the rules ahead of time
  into code; interpreting them gives the same endpoints (every endpointTests case
  passes).
- **Errors** (`aws/errors.lua`, generator `gen/aws.lua` `error_class`):
  - Lookup by code: the classes of the operation, then COMMON_ERRORS (Distilled's list
    and categories). Each code is tried as is, as its `awsQueryError` code, and without
    an `Exception`/`Error` suffix.
  - Synthetic error matchers (code plus message) run first.
  - When no code matches: a single declared status match is used. Otherwise a 5xx gives
    `InternalError` (restXml) or a `ParseError`, and any other unmatched code gives
    `UnknownAwsError { code, service, operation, body }`.
  - The class tag is `aws.codegen#errorTag` (EC2's `InvalidInstanceID.NotFound`), and
    operations name their errors by it.
  - Categories come from the traits (httpError status, `@retryable`), plus
    `awsRetryCategories` (AWS_THROTTLING_CODES, AWS_TRANSIENT_CODES, 500/502/503/504)
    and the name rules.
  - A class in the `ThrottlingError` category is throttling, so retry backs off longer.
  - JSON error bodies decode through the error's structure (`jsonName`, timestamps,
    nested shapes).
  - Header-bound error members are read from the response headers.
- **Credentials** (`aws/credentials.lua`, `from-node-provider-chain.ts` order):
  1. The environment (skipped when a profile is named).
  2. The shared files:
     - static keys;
     - `role_arn` with `source_profile` or `credential_source`, via STS AssumeRole
       (signed by the source; `mfa_serial` with an `mfa_code` callback; cycles reported);
     - web identity;
     - `credential_process`;
     - SSO, from the `aws sso login` cache, with an OIDC refresh.
  3. `credential_process`.
  4. The web identity token file.
  5. Container (ECS/EKS: relative or full URI, a token or a token file, URL checks,
     3 retries).
  6. Instance metadata (IMDSv2, falling back to v1 unless disabled; static stability).

  Also: `aws_credentials.static{...}`, `.env()`, `.profile{...}`, `.process(name)`,
  `.token_file{...}`, `.web_token{...}`, `.container()`, `.instance_metadata()`,
  `.chain{ profile, mfa_code }`.
  - Every process runs through `host.exec`, and every request through `host.transport`.
  - Credentials within 5 minutes of `expiration` are resolved again before the call.
  - Errors are `AwsCredentialsError { provider, hints }` and never quote a key, a token
    or a command's output.
- **Generator** (`gen/aws.lua`, plus hooks gated on `m.is_aws` in `gen/model.lua`,
  `gen/init.lua`, `gen/ops.lua`, `gen/shapes.lua`, `gen/types.lua` and `gen/traits.lua`):
  - **Model input:**
    - service resources;
    - RPC operations without `smithy.api#http` (`POST /`);
    - errors without `smithy.api#error`.
  - **Trait handling:**
    - every `aws.*`, xml and endpoint trait is in `traits.AWS`: handled or ignored on
      purpose, so an unknown one fails generation;
    - pagination merges the service's `smithy.api#paginated` (string tokens, map tokens
      such as DynamoDB's `ExclusiveStartKey`, absent items);
    - members are required unless `clientOptional`;
    - sparse lists and maps become `S.nullable` elements.
  - **Docs:** HTML is reduced to the first paragraph, as text of at most 400 bytes.
  - **Output:** the class is named after the sdkId (`DynamoDB`, `Route53`), and each
    service gets `init.lua` (the protocol facts), `endpoints.lua` and an AWS README.
  - **Layout:** large services are split by task 18's layout (EC2: `service.lua` plus
    `service/`).

## How a user reaches it

```lua
local aws = require("aws")                    -- clients/aws/init.lua, lazy index
local DynamoDB = require("aws.dynamodb")
local db = DynamoDB.new({
  region = "eu-west-1",                       -- else AWS_REGION / the profile
  host = require("distilled.host.popen")(),  -- or distilled.host.rex
  -- credentials = require("distilled.aws.credentials").chain({ profile = "admin" }),
  -- endpoint = "http://localhost:4566",      -- LocalStack; also AWS_ENDPOINT_URL
})
local out, err = db:put_item({ TableName = "users", Item = { id = { S = "u-1" } } })
if err and err.tag == "ConditionalCheckFailedException" then ... end
for name in db:list_tables_items({}) do print(name) end
```

Member names are the Smithy names (`TableName`, `QueueUrl`), as in Distilled. Blobs are
Lua strings, timestamps are epoch seconds, and secrets come back as `distilled.secret`.

## Driving it with `dl`

| Command | Proves |
| --- | --- |
| `verify/dl test aws_` | `spec/aws_protocol_spec.lua`: the Smithy AWS protocol tests (smithy-aws-protocol-tests 1.75.0, the same `model.json` Distilled runs): 715 client request/response/error cases for awsJson1_0/1_1, awsQuery, ec2Query, restJson1 and restXml, 0 failed; 13 skipped as Distilled skips them (server-only, `defaults`, host-prefixed request cases). `aws_credentials_spec` (32 cases ported from `credential-providers.test.ts`), `aws_client_spec` (retry, region, endpoint, tokens, expiry, secrets, SigV2, bearer, gzip, pagination, X-Ray, 4,000-item lists), `aws_runtime_spec` (977 endpointTests cases of 12 services through the shipped rule sets, gzip checked by an inflater, SigV2, error codes). On lua, luajit and Rex. |
| `luajit verify/lib/aws_protocol_tests.lua [svc] [case]` | The protocol-tests runner on its own, with a per-service table and a diff for each failure. |
| `luajit verify/lib/aws_endpoint_tests.lua` | All 14,066 `endpointTests` cases of the 433 models: 0 failed (lua and luajit; it lists files with `io.popen`). |
| `verify/dl conform aws [--replay]` | A differential test against Distilled. `verify/conform/node/aws.mjs` runs Distilled's generated services (`packages/aws/src/services/*.ts`) through a fake HttpClient. `verify/conform/aws_compare.lua` runs `clients/aws` with the same canned responses and compares: method, URL, query, headers, SigV4 scope and signed headers, body (JSON as values, form pairs, canonical XML), decoded value, error tag, message and fields. 36 cases over DynamoDB, SQS, SNS, STS, IAM, EC2, Lambda, Route 53, S3 Control, CloudFront, CloudWatch and SimpleDB (where the SigV2 signatures match byte for byte); 36 passed on lua, luajit and Rex. `--replay` needs no Node (`verify/conform/ref/aws/outcomes.json`). |
| `lua verify/lib/aws_call_all.lua .` (or `verify/dl rex verify/lib/aws_call_all.lua root=$PWD`) | Every one of the 19,429 operations called through its client, with a synthesized minimal input, once against a protocol-shaped empty success and once against a throttling error. 0 raised; 19,381 decode; the 58 event-stream calls are refused as acknowledged; 188 are the modelled refusals of the synthetic input (`EndpointError` for a KVS ARN "x", and EC2's undeclared `RequestLimitExceeded` as `UnknownAwsError`, as in Distilled); every other error from the throttling response is a throttling
error. On all three runtimes (Rex takes 2.5 min). |
| `verify/dl gen-diff aws` | Regenerates all 433 services (identical under lua and luajit), diffs against `clients/aws`, runs `stylua --check`, and loads and checks every service in all three runtimes (117,527 shapes, 271,127 refs, 19,400 requests built). |
| `verify/dl parity` | aws 19,429 of 19,631 (the 7 retired services above). |

Generation: `bin/distilled-lua package --models models/aws --provider providers/aws.lua
--out clients/aws` takes 30 s on luajit. `clients/aws` is 106 MB: `types.lua` 57 MB of
LuaLS annotations that are never loaded, `service.lua` and `service/` 39 MB,
`endpoints.lua` 2 MB, READMEs 5 MB. Distilled's `src/services` is 68 MB.

Load time for EC2, the largest model: `require("aws.ec2")` takes 10.6 ms on lua, 9.3 ms
on luajit and 38 ms in Rex. The first `describe_instances` call takes 17.5, 19.9 and
105 ms.

## Gotchas

- **Map order.** A Lua table has no key order. Map entries are serialised in sorted key
  order (`MessageAttributes.entry.N`, XML `<entry>`); Distilled uses insertion order.
  The protocol-tests runner compares XML maps without regard to entry order, and the
  SNS conform case lists its keys sorted. The server treats the two as the same request.
- **gopher-lua's `table.concat` fails past about 2,500 items.** Every list-sized join
  in the protocols uses `compat.concat` (EC2 `InstanceIds`, Route 53 change batches);
  `aws_client_spec` sends 4,000 items in Rex.
- **`emit.list` values.** An `emit.list` is `{ items = ... }`, not a Lua list. The
  error hook first read `d.categories` with `ipairs` and dropped every trait-derived
  category (fixed; found by `aws_call_all` and task 25's conform spec).
- **ParseError.** An AWS `ParseError` has no category, as in Distilled (the core class
  has the `ParseError` category). The tag is the same, so code that matches by tag sees
  no difference.
- **No body vs an empty body.** A 5xx with no body and no code is a `ParseError` that is
  not retried, as in Distilled (`internal_error` conform case). `InternalError` comes
  only from restXml's status table.
- **Withheld values.** Error messages withhold the value
  (`Expected a value, got "[REDACTED]" at [...]`) when the operation's input, output or
  declared errors can hold a secret (`redact.holds_sensitive`, cached on the op).
- **`trace_parent` needs a tracer.** Without tracing no trace header is sent (the same
  as the REST protocol).
- **Not ported:**
  - Cognito identity (`fromCognitoIdentity*`), `fromTemporaryCredentials` as a
    standalone source, and `login_session` profiles (DPoP). The chain does not use any of
    these, except `login_session`: such a profile fails with "uses login_session
    (`aws login`), which distilled-lua does not support yet", and the chain stops there.
  - SigV4A: an endpoint that asks for it fails with `SdkError` (4 models list
    `aws.auth#sigv4a`).
  - Event streams: the 58 operations are refused.
  - `Presign` is S3's (task 25, `distilled.s3.presign`).
