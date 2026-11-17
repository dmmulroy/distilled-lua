# Task 17: AWS (434 models, ~19,600 operations) except S3: done

## What was built

- **`clients/aws/`** (generated and committed; `require("aws.<service>")`, with a lazy
  index at `require("aws")`): 433 services and 19,429 operations. `providers/aws.lua`
  skips `s3` (task 25) and `ses-events` (payload types, no operations).
  - `dl parity`: aws 19,429 of 19,631. Each generated service has exactly Distilled's
    operation count. The 202 missing belong to the 7 services AWS removed from its spec
    mirror: finspace, finspace-data, iot-events, iot-events-data, panorama,
    simspaceweaver, tnb. Distilled keeps their old generated files; there is no model
    to generate from.
  - SimpleDB comes from Distilled's `manual-specs/`.
  - 58 event-stream operations are generated and refuse the call with `SdkError`
    (`allow_unsupported = { "streaming" }`).
- **Generator** (`lua/distilled/gen/aws.lua`), with small hooks gated on `m.is_aws` /
  `ctx.aws` in `gen/{init,model,ops,shapes,types,traits}.lua`:
  - **Model features:**
    - service resources;
    - RPC operations without `smithy.api#http`;
    - errors without `smithy.api#error`;
    - every `aws.protocols#*`, `aws.api#*` and `aws.auth#*` trait;
    - `smithy.rules#endpointRuleSet` (`endpointBdd`, the same rules as a BDD, is ignored);
    - the xml traits, `ec2QueryName`, `awsQueryError`, `httpChecksum`,
      `requestCompression`, host prefixes and `hostLabel`, idempotency tokens;
    - `contextParam` and `staticContextParams`;
    - pagination merged from the service, with map tokens;
    - sparse collections, unions and `clientOptional`;
    - xray telemetry propagation.
  - **Error classes:**
    - tag from `aws.codegen#errorTag`, which ops name their errors by;
    - categories from the traits plus `awsRetryCategories` and the name rules;
    - synthetic matchers;
    - JSON error bodies decode through the error's shape.
  - **Output:**
    - docs reduced to a first paragraph of plain text (at most 400 bytes);
    - the class is named after the sdkId;
    - per service: `init.lua` (the protocol facts), `endpoints.lua` (rules as JSON) and
      an AWS README.
  - Every AWS trait is in `traits.AWS`, handled or ignored on purpose. The `aws.` and
    `smithy.rules#` namespaces are guarded, so an unknown trait fails generation.
- **Runtime** (`lua/distilled/aws/`):
  - `protocol.lua`, the call pipeline in Distilled's order:
    - idempotency tokens, serialise, gzip, httpChecksum;
    - endpoint resolution (custom endpoint, `AWS_ENDPOINT_URL`, or the rules, with
      authSchemes), host prefix;
    - signing: SigV4 on every attempt, or SigV2, or a bearer token;
    - X-Ray propagation;
    - region order, expiry refresh, decode, error mapping.
  - Protocols:
    - `json_protocols.lua`: awsJson1_0/1_1 and restJson1, with the API Gateway and
      Glacier customizations;
    - `query.lua`: awsQuery and ec2Query;
    - `rest_xml.lua`: restXml, ported here for Route 53, CloudFront and S3 Control,
      and used by task 25.
  - Shared: `http.lua` (bindings), `codec.lua` (values, timestamps, base64, failures).
  - Endpoints: `endpoint.lua` and `partitions.lua` (a rules engine interpreter).
  - `errors.lua`: COMMON_ERRORS and the code table.
  - `credentials.lua`, the `fromNodeProviderChain` order:
    - env;
    - ini (static, assume role via STS with MFA, web identity, `credential_process`,
      SSO with OIDC refresh);
    - process;
    - token file;
    - container;
    - IMDSv2/v1.
  - `gzip.lua` (pure Lua deflate) and `sigv2.lua`.
- **Verification tools:**
  - `verify/lib/aws_protocol_tests.lua`: the Smithy AWS protocol tests runner, a port of
    `protocol-tests.test.ts`; its fixture is `spec/fixtures/aws/protocol-tests.json`.
  - `verify/lib/aws_endpoint_tests.lua`: every endpointTests case.
  - `verify/lib/aws_call_all.lua`: every operation, end to end.
  - `dl conform aws`: `verify/conform/node/aws.mjs`, `verify/conform/aws_compare.lua`,
    the cases in `verify/conform/cases/aws.json` and the reference in
    `verify/conform/ref/aws/outcomes.json`.
- **Specs:**
  - `spec/aws_protocol_spec.lua`;
  - `spec/aws_credentials_spec.lua` (ported from `credential-providers.test.ts`);
  - `spec/aws_client_spec.lua`;
  - `spec/aws_runtime_spec.lua`;
  - fixtures in `spec/fixtures/aws/`.
- **Docs:** `verify/features/aws.md` and the "17 aws" section of STATUS.md.

## Commands run and their output (after the final `git merge main`, 8021bf7)

```text
$ verify/dl doctor
... doctor: ok

$ verify/dl test
  lua: ok 2506 passed, 8 pending [Lua 5.5]
  luajit: ok 2506 passed, 8 pending [luajit]
  rex: ok 2493 passed, 14 pending [rex]

$ verify/dl test aws_          (protocol, credentials, client, runtime specs)
  lua: ok 81 passed [Lua 5.5]
  luajit: ok 81 passed [luajit]
  rex: ok 81 passed [rex]

$ luajit verify/lib/aws_protocol_tests.lua
AwsEc2                       passed   57  failed    0  skipped   2
AwsQuery                     passed   75  failed    0  skipped   2
JsonProtocol                 passed  116  failed    0  skipped   2
JsonRpc10                    passed   54  failed    0  skipped   2
QueryCompatibleJsonRpc10     passed    3  failed    0  skipped   0
RestJson                     passed  233  failed    0  skipped   2
RestXml                      passed  175  failed    0  skipped   3
RestXmlWithNamespace         passed    2  failed    0  skipped   0
total: passed 715, failed 0, skipped 13

$ lua verify/lib/aws_endpoint_tests.lua models/aws      (and luajit)
endpoint tests: 434 services, 14066 cases, 0 failed

$ verify/dl conform aws            (Node: Distilled's services; then lua)
aws: 36 cases -> verify/conform/ref/aws/outcomes.json
conform aws [Lua 5.5]: 36 passed, 0 failed
$ verify/dl conform aws --replay
conform aws [Lua 5.5]: 36 passed, 0 failed
conform aws [luajit]: 36 passed, 0 failed
conform aws [rex]: 36 passed, 0 failed

$ lua verify/lib/aws_call_all.lua .     (and luajit; rex via verify/dl rex ... root=$PWD)
aws call-all [Lua 5.5]: 433 services, 19429 ops, 19381 ok, 0 raised, 58 acknowledged unsupported, 188 expected refusals, 0 findings
aws call-all [luajit]: 433 services, 19429 ops, 19381 ok, 0 raised, 58 acknowledged unsupported, 188 expected refusals, 0 findings
aws call-all [rex]: 433 services, 19429 ops, 19381 ok, 0 raised, 58 acknowledged unsupported, 188 expected refusals, 0 findings

$ verify/dl gen-diff aws
ok   generate: package aws: 433 ok, 0 failed, 2 skipped; 19429 operations -> aws
ok   generate: lua and luajit write identical files
ok   diff: clients/aws matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 433 services, 117527 shapes, 271127 refs resolved, 19400/19429 ops built, 29 acknowledged unsupported; ...
ok gen-check luajit: ... (same)
ok gen-check rex: ... (same)
gen-diff aws: ok

$ verify/dl parity
aws                 19631    19429    433/433      202  yes
s3                    112      112        1/0        0  yes

$ verify/dl test s3_      (task 25's specs, after the fixes below)
  lua / luajit / rex: ok 169 passed, 1 pending
```

How the evidence covers the proof bar:

- **Conformance against Distilled:**
  - The Smithy protocol tests are the same `model.json` Distilled runs.
  - `dl conform aws` diffs our requests and outcomes against Distilled's own TS services
    for DynamoDB, SQS, SNS, STS, IAM, EC2, Lambda, Route 53, S3 Control, CloudFront,
    CloudWatch and SimpleDB. The SimpleDB SigV2 signatures are byte-identical.
- **Error, empty and retry paths:**
  - throttling retried with backoff and re-signed;
  - transient 5xx retried until the attempts run out;
  - an empty 5xx is a ParseError that is not retried, as in Distilled;
  - declared, common, unknown and query-compatible codes;
  - a missing region; expired credentials; a missing required label;
  - empty streams, empty lists and maps, sparse nulls.
- **Network:** none. Every test uses scripted transports; the conform Node side uses a
  fake HttpClient.

Generation takes 30 s on luajit. `clients/aws` is 106 MB: 57 MB of it is LuaLS
`types.lua`, which is never loaded; Distilled's `src/services` is 68 MB. For EC2, the
largest service, `require` takes 10.6 ms on lua, 9.3 ms on luajit and 38 ms in Rex.

## Fixed for task 25 (its "For task 17" list)

Each of these is in `lua/distilled/aws/`; the S3 conformance spec's KNOWN list is now
empty:

- raw blob payloads read by name;
- an empty streaming payload decodes as `""`;
- `s3UnwrappedXmlOutput` is read from the operation;
- a missing required label fails before sending;
- error categories, InternalError and ParseError match Distilled;
- withheld values are shown as `"[REDACTED]"`.

The error-category fix was a bug of mine: an `emit.list` read with `ipairs` dropped
every trait-derived category. To pick the fixes up I regenerated `clients/s3` and made
two edits to `spec/s3_conform_spec.lua`: removed the KNOWN entries, and normalised an
empty expected body the way an empty actual body already was.

## Skipped, and why

- **Event streams** (58 operations): refused with `SdkError`, acknowledged in the
  provider spec. There is no eventstream codec; the brief allows it.
- **SigV4A**: an endpoint that requires it fails with `SdkError` (4 models list
  `aws.auth#sigv4a`). No SigV4A signer exists in `distilled.sigv4`.
- **rpcv2Cbor**: never selected, as in Distilled.
- **Credential sources Distilled has but the default chain does not use:**
  `fromCognitoIdentity`/`Pool` and `fromTemporaryCredentials` as standalone sources.
  `login_session` profiles (DPoP) are also not ported; such a profile fails with a
  "not supported yet" message.
- **`dl conform aws` Node side:** needs the Distilled checkout with `node_modules`. Without
  it, `--replay` uses the saved reference, as I did for luajit and Rex.
- **`aws_endpoint_tests.lua`** lists files with `io.popen`, so it runs under lua and
  luajit only. Rex covers 977 of the cases through `spec/aws_runtime_spec.lua`.
- **Live AWS calls:** none (no network in tests).

## Open problems / for the orchestrator

- `verify/features/README.md` needs a row for `aws.md`.
- `providers/s3.lua` could use `parse_tag = "ParseError"` now; I checked that it
  generates.
- `docs/interfaces.md` could gain a `distilled.aws.*` section; "What others can use" in
  STATUS.md (17 aws) is the contract.
- **Edits outside my list:**
  - `verify/dl`: `conform aws`, and the `models sync` manual-specs copy (main's version
    after the merge);
  - `spec/provider_spec.lua`: the `aws` entry;
  - `spec/s3_conform_spec.lua` and `clients/s3`: see "Fixed for task 25" above.
