# Phase 2: parity with Distilled's published SDKs

Goal: a Lua client for every API Distilled publishes as `@distilled.cloud/<pkg>` (about 115
packages, see `ls ../distilled/packages`), not only Neon. Tasks 10 onwards build toward it.
Several agents run at once, **each in its own git worktree** (a sibling directory
`../distilled-lua-<task>` on branch `task-<NN>`); the orchestrator merges branches into
`main`. Commit on your branch only. Never push, never touch `main` or another worktree.

Read `AGENTS.md` (hard rules, gopher-lua defects, proof bar), `STATUS.md` and your brief.
The proof bar of `AGENTS.md` applies unchanged.

## State at the start of phase 2 (measured by the orchestrator)

- Every spec mirror except aws, azure, gcp, cloudflare and tencentcloud is fetched, `pnpm
  install` is done in `../distilled`, and every package's `scripts/convert.ts` has been run:
  the patched Smithy models are in `../distilled/packages/<pkg>/.generated-specs/*.json`
  (1,203 models, 335 MB). GraphQL packages (linear, railway, expo-eas) wrote
  `../distilled/packages/<pkg>/.generated-graphql/<pkg>.json` instead (not Smithy).
  Do not modify tracked files under `../distilled`; re-running a `convert` is fine.
- Smoke test: each model generated with a dummy provider spec (bearer auth,
  `naming.members = "wire"`), script `tasks/notes/smoke-run1.sh <pkg>/<model>`, results in
  `tasks/notes/smoke-results.txt`: **939 of 1,206 models generate**, 267 fail. Failure
  classes (count of models):
  - nullable list items / nullable map values "have no representation in the schema
    contract" (~60 models: posthog, github, datadog, anthropic, okta, plaid, ...)
  - `smithy.api#http` with keys `baseUrl` (scaleway 98, stackit 52), `server`
    (digitalocean), `accept` (mongodb-atlas)
  - `com.distilled.grpc#serverStreaming` / `com.distilled.openapi#streamWhen` (modal,
    boxd, boat-dev): streaming operations
  - a nullable `rawResponse` member (anthropic, discord, polymarket, vercel)
  - a shape's type name collides with the client class (`Client`), the module
    (`Module`) or a built-in error class (`NotFound`, `Forbidden`) (auth0, clerk,
    launchdarkly, grafana, onepassword, redis-cloud, starburst-galaxy, ...)
  - pagination: `_items` method collides with a real operation (exa); cursor pagination
    without `outputToken` (resend)
  - `distilled.errors#bodies` targeting a prelude shape like `smithy.api#Double` (coinflow)
  - a path label with no member (proxmox `{url_seq}`)
  - models with no operations (github/webhooks, resend/webhook_events): skip, as
    Distilled does
- Operation counts of the TypeScript SDKs (parity target): `tasks/notes/ts-op-counts.txt`
  (`API.make` + `API.makePaginated` + `API.makeStreaming` in `src/services/*.ts`).

## Decisions (made by the orchestrator; authoritative)

- **Lua module names**: package name with `-` replaced by `_` (`fly_io`, `mongodb_atlas`,
  `redis_cloud`). A package with one model is `clients/<lua>/`, `require("<lua>")`. A
  package with several models is `clients/<lua>/<model>/`, `require("<lua>.<model>")`,
  with model names snake_cased the same way; `clients/<lua>/init.lua` is then a small
  index module (task 10 decides its exact shape).
- **Models are not committed** (as in Distilled, where `.generated-specs` is ignored):
  `models/<pkg>/<model>.json` is produced by a sync command from `../distilled`, and git
  ignores `models/` except what conformance needs. Generated **clients are committed**
  (as Distilled commits `src/services`).
- One provider spec per package: `providers/<lua>.lua`, shared by all its models.
- Operations the runtime cannot perform yet (streaming, until it exists) are emitted and
  fail at call time with `SdkError`, through `allow_unsupported`, rather than failing a
  whole model: parity counts operations.
- Protocol families, in order: plain REST/JSON (most packages) first; then signing
  (AWS SigV4, Tencent TC3, HMAC/JWT schemes), XML, Cloudflare's envelope, GCP/Azure,
  GraphQL, gRPC.

## Task map

| Task | Worktree branch | What |
| --- | --- | --- |
| 10 layout | task-10 | models sync, multi-model packages, `gen-all`, parity report |
| 11 schema | task-11 | nullable list items / map values, nullable rawResponse, type-name collisions |
| 12 traits | task-12 | http `baseUrl`/`server`/`accept`, streaming as unsupported, pagination edge cases, errors#bodies prelude, missing labels |
| 13 providers | task-13 | survey every REST package's hand-written glue; provider-spec features it needs |
| 14 crypto | task-14 | pure-Lua SHA-256/SHA-1/HMAC/base64/hex; AWS SigV4 signer |
| 15 xml | task-15 | XML codec (port of core `xml.ts`) |

Later tasks (provider-spec batches, AWS protocols, Cloudflare, GCP, Azure, GraphQL, gRPC)
are written once these land.
