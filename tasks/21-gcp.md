# Task 21: GCP (315 stable + 214 unstable models) and Google Workspace

Read `tasks/10-parity-overview.md` and `STATUS.md` (10-18, 24 if merged) first. GCP's
`.generated-specs/` has `stable/` and `unstable/` subdirectories, which `verify/dl models
sync` does not copy yet (task 10 STATUS): decide the layout (mirror Distilled's
`@distilled.cloud/gcp/<service>` and its unstable entry point). Glue:
`../distilled/packages/gcp/src/` (protocol.ts, endpoint.ts, regional-endpoints.ts,
region.ts, credentials*.ts, credential-providers/: access token, ADC, authorized user
refresh token, metadata server, service-account key (RS256 JWT: task 24 builds RSA;
until it lands, implement everything else and leave that provider failing with a clear
ConfigError), workload identity) and `../distilled/packages/google-workspace/src/`.

## Files you own

```text
lua/distilled/gcp/*.lua (new)          protocol, endpoints, credentials chain
lua/distilled/gen/*                    ONLY discovery-model support (flatten-payload etc.;
                                       prefer a new file + hooks)
verify/dl                              ONLY models sync for the stable/unstable layout
providers/gcp.lua, providers/google_workspace.lua
clients/gcp/, clients/google_workspace/ (generated, committed)
spec/gcp_*_spec.lua, verify/features/gcp.md
STATUS.md (section "21 gcp")
```

## Requirements

1. Port protocol and credentials faithfully (token refresh per attempt, quota project
   header, user agent, regional endpoints, error envelope, pagination with pageToken,
   LROs if Distilled models them).
2. All models generate, load in three runtimes, build every request (`gen-diff`).
3. Conformance against Distilled's TS for a sample of operations.
