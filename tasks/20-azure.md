# Task 20: Azure (223 models, ~13,900 operations)

Read `tasks/10-parity-overview.md` and `STATUS.md` (10-18) first. Models:
`verify/dl models sync azure`. Smoke today: 0/223 (`com.distilled.openapi#apiVersion`
unsupported, ...). Glue: `../distilled/packages/azure/src/` (protocol.ts, credentials.ts,
errors.ts, retry.ts, traits.ts): ARM base URL, `api-version` query parameter per
operation, long-running operations if Distilled handles them, error envelope
`{ error: { code, message } }`, Entra ID OAuth (client credentials, maybe CLI token via
`az account get-access-token` through host.exec, managed identity), subscription ids.

## Files you own

```text
lua/distilled/azure/*.lua or protocol/azure.lua (new)
lua/distilled/gen/*   ONLY Azure model support (apiVersion trait etc.; prefer a new file + hooks)
providers/azure.lua, clients/azure/ (generated, committed)
spec/azure_*_spec.lua, verify/features/azure.md
STATUS.md (section "20 azure")
```

## Requirements

1. Port the Azure glue faithfully (auth flows Distilled supports, token caching and
   refresh per attempt, api-version, LRO polling if present, pagination via nextLink).
2. All models generate, load in three runtimes, build every request (`gen-diff`);
   coordinate with task 18 on output size.
3. Conformance against Distilled's TS for a sample of operations.
