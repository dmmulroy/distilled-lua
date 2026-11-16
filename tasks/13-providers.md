# Task 13: provider survey and provider-spec features

Read `tasks/10-parity-overview.md` first.

Every Distilled REST package has hand-written glue: `src/protocol.ts`, `src/credentials.ts`,
`src/errors.ts` (and sometimes `src/pagination.ts`, `src/retry.ts`, `src/traits.ts`).
Our provider spec (`lua/distilled/gen/provider.lua`, `docs/generating.md` section 4) can
express bearer or single-header auth, a base URL with one env override, an error
envelope and a status map. Find out what the rest of the packages need, and add it.

## Files you own

```text
docs/providers-survey.md (new)         the survey table
lua/distilled/gen/provider.lua         new keys (not the UNSUPPORTED table: task 12)
lua/distilled/gen/init.lua             ONLY emitting the protocol/options for new keys
lua/distilled/protocol/rest.lua        auth / headers / error-envelope features
                                       (task 12 adds per-op base URL; keep edits apart)
lua/distilled/credentials.lua
providers/*.lua (new, except neon.lua and hetzner.lua)
spec/provider_spec.lua, spec/rest_spec.lua (new cases)
docs/generating.md                     section 4 only
STATUS.md (section "13 providers")
```

## Requirements

1. Survey every package under `../distilled/packages` except aws, aws4signer, s3, azure,
   gcp, google-workspace, cloudflare, tencentcloud, core, dev and the GraphQL ones
   (linear, railway, expo-eas). For each: auth scheme (bearer, custom header, basic,
   query parameter, several headers, OAuth client credentials, signed requests, ...), env
   variables and defaults, base URL (fixed, per region, templated from an option like a
   subdomain or site, per-operation), error envelope and fields, extra headers (versions,
   user agents), special pagination or retry, anything else in protocol.ts. Classify each
   package: **A** expressible with today's spec, **B** needs a spec feature you add here,
   **C** needs crypto/signing (task 14) or another protocol (note which). Write it to
   `docs/providers-survey.md`, one row per package, with the exact values.
2. Implement the B features (strictly validated, documented, with specs): likely basic
   auth, query-parameter auth, several headers / fixed extra headers, templated base URL
   from options, optional auth, alternative credentials (token OR key). Mirror the
   behaviour of the TS glue exactly, including env variable names and defaults.
3. Write `providers/<lua>.lua` for every A and B package (mirroring its TS glue; comments
   cite the TS files as `providers/neon.lua` does). Do not generate or commit clients:
   the orchestrator runs `gen-all` after merging task 10. Do check each spec loads with
   `provider.validate` (a spec for it) and that a single model of each generates into
   `/tmp` with `bin/distilled-lua generate`.
4. Note in STATUS.md anything task 12 must provide (per-op base URL variables) and how
   your spec keys feed it.
