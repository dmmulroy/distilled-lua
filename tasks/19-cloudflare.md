# Task 19: Cloudflare (130 models, ~3,100 operations)

Read `tasks/10-parity-overview.md` and `STATUS.md` (10-18) first. Models:
`verify/dl models sync cloudflare` (Distilled's convert for it is
`scripts/spec-to-smithy.ts`; `.generated-specs/` already holds 130 models incl.
`cloudflare.protocols.json`). Smoke today: 67/130 generate with a dummy spec; the rest fail
on pagination traits whose pageSize/items paths point into the envelope (`perPage`,
`result.items`).

Distilled's glue: `../distilled/packages/cloudflare/src/` (protocol.ts 746 lines: the
`{ success, errors, messages, result, result_info }` envelope, auth by API token or
key+email, account/zone ids, jurisdictions, pagination, retry, telemetry).

## Files you own

```text
lua/distilled/cloudflare/*.lua or protocol/cloudflare.lua (new)
lua/distilled/gen/*        ONLY Cloudflare model support (prefer a new file + small hooks)
lua/distilled/paginate.lua ONLY new pagination styles Cloudflare needs (keep Neon's intact)
providers/cloudflare.lua, clients/cloudflare/ (generated, committed)
spec/cloudflare_*_spec.lua, verify/features/cloudflare.md
STATUS.md (section "19 cloudflare")
```

## Requirements

1. Port protocol.ts faithfully: envelope unwrapping, error codes -> classes (including
   Distilled's patched per-code matchers), auth modes and env variables, multipart and
   non-JSON bodies, base URL and jurisdiction handling, pagination (page/per_page,
   cursor, result_info).
2. All 130 models generate, load in three runtimes, build every request (`gen-diff`).
3. Conformance against Distilled's TS for a sample of operations per model family
   (requests and parsed outcomes for envelope success, envelope error, pagination).
