# Task 17: AWS (434 models, ~19,600 operations) except S3

Read `tasks/10-parity-overview.md`, `STATUS.md` (10-16, 18) and `verify/features/crypto.md`
(`distilled.sigv4` exists, task 14) and `verify/features/xml.md` (`distilled.xml`, task 15).

Distilled's AWS package: `../distilled/packages/aws/src/` (protocols/aws-json.ts,
aws-query.ts, ec2-query.ts, rest-json.ts; restXml lives with S3 in
`../distilled/packages/s3/src/protocols`, port it here too for the non-S3 restXml services
such as Route 53 and CloudFront; endpoint.ts, region.ts, credentials*.ts,
credential-providers/, retry.ts, errors.ts, customizations/, presign.ts, sigv2.ts).
Models: `verify/dl models sync aws` -> `models/aws/*.json` (native Smithy, converted by
Distilled with patches). Smoke today: 0/434 generate (`service resources are not
supported`, `telemetry propagation xray`, token pagination without tokens, ...).

## Files you own

```text
lua/distilled/aws/*.lua (new)            protocols, endpoints, region, credentials chain, errors
lua/distilled/protocol/aws_*.lua (new)   if you prefer protocol/ for the protocol modules
lua/distilled/gen/*                      ONLY AWS model support (resources, aws.* traits,
                                         xray propagation, pagination variants). Prefer new
                                         files (gen/aws.lua) plus small hooks; other agents
                                         edit gen/ in parallel.
providers/aws.lua, clients/aws/ (generated, committed)
spec/aws_*_spec.lua, verify/features/aws.md
STATUS.md (section "17 aws")
```

## Requirements

1. Generator: accept AWS Smithy models (service `resources`, resource shapes, every
   `aws.protocols#*`, `aws.api#*`, `aws.auth#sigv4`, `smithy.rules#endpointRuleSet` (port
   the rules engine or Distilled's simplified endpoint resolution, whichever Distilled
   uses), `smithy.api#xmlName`/`xmlFlattened`/`xmlAttribute`/`xmlNamespace`,
   `awsQueryError`, `ec2QueryName`, `httpChecksum`, `smithy.api#streaming` (as
   unsupported unless trivial), host prefixes, idempotency tokens (needs a UUID from
   host.random), `xray` telemetry propagation (port core telemetry-xray.ts or emit
   it as unsupported-but-harmless).
2. Protocols: awsJson1_0/1_1, restJson1, awsQuery, ec2Query, restXml: request
   serialisation and response/error parsing exactly as Distilled (port its tests). SigV4
   signing through `distilled.sigv4` on every request (per-attempt credentials).
3. Credentials: env, shared config/credentials files (profiles, `source_profile` +
   `role_arn` via STS AssumeRole, `credential_process` through `host.exec`), SSO cached
   token if Distilled has it, container and instance metadata over the transport. Region
   from options/env/config. Mirror `from-node-provider-chain.ts` order.
4. Layout: `clients/aws/<service>/`, `require("aws.<service>")`, package index (task 10).
   Generation time and output size must be reasonable: coordinate with task 18 (large
   models; read its STATUS section, merge main often).
5. Conformance: extend `verify/conform` (or a new `dl conform aws`) to diff requests and
   parsed outcomes against Distilled's TS for a sample of every protocol (at least DynamoDB
   awsJson1_0, SQS/SNS query, EC2 ec2Query, Lambda restJson1, Route 53 restXml).
6. `verify/dl parity` shows aws operations ≈ the TS count; list anything missing and why.
