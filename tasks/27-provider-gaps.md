# Task 27: provider gaps left by task 13

Read `tasks/10-parity-overview.md`, `STATUS.md` (section 13 especially) and
`docs/providers-survey.md` first.

## Files you own

```text
lua/distilled/gen/provider.lua   models.override carrying auth / options / headers
lua/distilled/protocol/rest.lua  form-urlencoded bodies, Slack's ok:false mapping,
                                 Scaleway input transforms (region/zone defaults)
lua/distilled/request.lua        ONLY form-urlencoded bodies
lua/distilled/transport/*.lua    ONLY keeping secrets out of process arguments for URLs
                                 (questrade: the refresh token travels in a URL query)
providers/slack.lua, scaleway.lua, questrade.lua, and the per-model-auth packages:
  clerk, convex, digitalocean, e2b (REST parts only; task 23 owns its Connect parts),
  exa, fly_io, mailchimp, onepassword
clients/ for exactly those packages (generated, committed, each passing gen-diff)
spec/*_spec.lua (new cases), docs/generating.md section 4
STATUS.md (section "27 provider-gaps")
```

## Requirements

1. `models.override` takes `auth`, `options` and `headers` per model, strictly
   validated; the multi-model packages above use it, mirroring their TS glue.
2. Slack (36 models): form-urlencoded request bodies where Distilled sends them, the
   `{ ok: false, error: "<slug>" }` envelope mapped to classes by slug, token kinds, as
   in `../distilled/packages/slack/src/protocol.ts`.
3. Scaleway (98 models): region/zone defaults filled into inputs/URLs
   (`../distilled/packages/scaleway/src/protocol.ts`), its error classification glue.
4. Questrade: OAuth refresh with the token in the URL query without exposing it in
   process arguments (popen_curl / exec_curl config files or stdin already carry headers;
   make the URL travel the same way), then its provider spec.
5. Each package: `verify/dl gen-diff <pkg>` passes; commit `clients/<pkg>/` per package;
   push `task-27` after each package.
