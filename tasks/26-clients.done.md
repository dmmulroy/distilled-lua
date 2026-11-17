# Task 26 (clients): done

## What was built

- Every package I own (89 of them) is generated and committed as `clients/<lua>/`, one
  commit per package (`clients: <pkg>`). That is every package with a REST provider spec
  except the excluded ones: aws, s3, cloudflare, azure, gcp, google_workspace,
  tencentcloud, modal, boxd, e2b, namespacelabs, slack, scaleway, questrade, and task 27's
  clerk, convex, digitalocean, exa, fly_io, mailchimp, onepassword. The GraphQL-only
  packages (linear, railway, expo_eas) were already committed by task 16.
  - 953 models generated.
  - 2 models skipped because they have no operations (Distilled skips them too):
    github/webhooks and resend/webhook_events.
  - 34,743 operations.
- neon was unchanged.
- hetzner was regenerated. Task 13's envelope emission had changed its `init.lua`
  (pointer lists).
- github's REST models were added next to task 16's `graphql/`.
- After `git merge main` brought in task 18, the 28 packages whose service passes the size
  threshold were regenerated in the split layout and committed again.
- infisical waited for task 18 and now generates and loads everywhere.

### Fixes, each with a spec

1. **`lua/distilled/gen/emit.lua`: code layout measures width in bytes.**
   - Why: stylua 2.6 measures width in bytes, which I measured: `"é"` counts 2, `"🔥"`
     counts 4. huggingface/papers has an enum of emoji that fits in 100 characters but not
     in 100 bytes. stylua expands it, but the generator kept it on one line, so
     `stylua --check` failed.
   - Change: a new function, `emit.code_width`. Comments still wrap by characters
     (`emit.width`), because stylua does not reflow comments.
   - Effect: no other committed client changed, checked by running gen-all again over
     every package.
   - Spec: `spec/gen_emit_spec.lua`, "measures code width in bytes…". Its layouts were
     checked with `stylua --check`.
2. **`verify/lib/gen_input.lua`: a cycle through a required list ends with an empty list.**
   - Why: starburst-galaxy/live_table `update_live_table_schema` requires `nestedColumns`
     inside its columns. gen-diff could not build an input for it and reported 204 of 205
     operations.
   - A cycle through required struct members still fails.
   - Spec: `spec/gen_input_spec.lua` (new; the manifest was regenerated). It fails
     without the fix.
3. **`verify/lib/parity.lua`: it undercounted Lua operations.** It now counts:
   - operations in the `service/ops_NNN.lua` files of a split service (task 18). Before
     this, apache-superset, auth0, zendesk and the others showed 0;
   - operations whose assignment stylua hangs, `ops.<long_name> =` with the table on the
     next line (doppler, workos, vercel).

No provider spec needed a change.

## Commands run (final, after `git merge main` at 535c691)

```text
$ verify/dl models sync                      # models sync: 2256 models
$ verify/dl gen-all <the 89 packages>        # gen-all: 89 packages; models: 953 ok, 0 failed, 2 skipped
$ git status --short                         # clean: the merge changed no committed client
$ for p in <the 89 packages>; do verify/dl gen-diff $p; done
  89 of 89: "gen-diff <pkg>: ok"
  - each run checks that lua and luajit produce identical files, that the diff against
    clients/ is empty, and that stylua --check is clean;
  - gen-check then runs on lua, luajit and rex: every ref is resolved and a request is
    built for each operation.
  rex gen-check total: 34,742 of 34,743 operations built. The remaining one is
    boat-dev's streaming operation, acknowledged unsupported (allow_unsupported).
  Slowest Rex service loads: posthog 458 ms, ovh 267 ms, github 184 ms, vercel 137 ms,
    kubernetes 120 ms; infisical 71 ms (split).
$ verify/dl doctor                           # doctor: ok
$ verify/dl fmt --check                      # exit 0
$ verify/dl test
  lua: ok 1599 passed, 5 pending [Lua 5.5]
  luajit: ok 1599 passed, 5 pending [luajit]
  rex: ok 1586 passed, 10 pending [rex]
$ verify/dl parity
  parity: 50124 of 106595 TS operations (47.0%) in 113 packages; 88 packages complete, 99 provider specs
```

## Packages below 100% parity

### My packages

None of these gaps comes from the generator. In each case the current
`.generated-specs` model, synced from `../distilled`, differs from the specs that
Distilled's committed `src/services` were generated from. There is no model to generate
from. I compared operation names one by one (TS export names against Lua op names).

| Package | TS | Lua | Why |
| --- | ---: | ---: | --- |
| whop | 451 | 437 | `src/services` has companies, entries, recommended_actions and ad_reports (14 ops); `models/whop/` has no such models |
| posthog | 2622 | 2612 | 10 `loops` ops in TS; no loops model in `models/posthog/` |
| coinflow | 207 | 213 | TS has 3 subsidiary ops that the merchant_accounts model lacks; the model has 9 embedded-account / withdrawal ops that TS lacks |

### Other owners' packages (not mine)

- **Task 27:** clerk, convex, digitalocean, exa, fly-io, mailchimp, onepassword (per-model
  auth); slack, scaleway, questrade. e2b's REST parts are also task 27.
- **Task 17 / 25:** aws, s3.
- **Task 19:** cloudflare.
- **Task 20:** azure.
- **Task 21:** gcp and google-workspace (not synced: subdirectories).
- **Task 23:** modal, boxd, namespacelabs, and e2b's Connect parts.
- **No provider spec (class C):** acme, coinbase, polymarket.

## Repository size

- The clients I committed hold 231 MB in 4,629 tracked files (93 packages with neon,
  hetzner and the GraphQL ones). The git pack grew by about 35 MB (compressed).
- After merging main, `clients/` holds 275 MB in 5,719 files (94 packages). Task 22's
  tencentcloud accounts for 45 MB of that, which would make it the largest package.
- By file type (my 93 packages):
  - `types.lua`: 118 MB (51%)
  - `service/` chunks: 56 MB
  - `service.lua`: 47 MB
  - `README.md`: 6.4 MB
  - `init.lua`: 2.1 MB
- Largest packages:

| Package | Size |
| --- | ---: |
| infisical | 29.3 MB |
| posthog | 20.0 MB |
| vercel | 13.5 MB |
| stripe | 12.6 MB |
| ovh | 11.2 MB |
| kubernetes | 10.4 MB |
| datadog | 10.2 MB |
| github | 9.1 MB |
| elasticsearch | 6.2 MB |
| sentry | 4.9 MB |
| whop | 4.9 MB |
| mongodb_atlas | 4.5 MB |

`types.lua` is only read by LuaLS. If size matters, the cheapest saving would be to make it
optional or to split it.

## Skipped or unverified

- **No live API calls**, per the rules. The proof is gen-diff:
  - generation is deterministic;
  - the output is formatted;
  - it loads on all three runtimes;
  - a request is built for every operation.
- There is no per-provider fixture exchange.
- **No conformance diffs** beyond `dl conform neon --replay`, which runs inside `dl test`
  through `spec/conform_replay_spec.lua`. The Node conformance scripts bind only Neon.

## Open problems

- **`verify/features/parity.md` will conflict** with other branches that regenerate it.
  Rerun `verify/dl parity` after merging.
- **Spec drift (whop, posthog, coinflow).** To match the TS SDK exactly, Distilled's specs
  would need to be re-fetched, or its services regenerated.
- **Size:** `types.lua` (above).
