# Task 13 (providers): done

## What was built

- `docs/providers-survey.md` covers 106 packages, one row each with exact values: auth,
  env variables and defaults, base URL, error envelope, extra headers, pagination/retry
  and protocol.ts details.
  - Class A: 18. Class B: 83. Class C: 5 (acme JWS, boxd gRPC-web, modal gRPC,
    coinbase CDP JWT, polymarket HMAC + EIP-712).
  - It also has a feature-to-key table and the cross-task dependencies.
- New provider-spec keys, validated by `lua/distilled/gen/provider_ext.lua`, which
  `provider.validate` calls:
  - `options` (typed, choices, defaults, secret) and env lists.
  - `headers` (fixed, from an option, or from env).
  - `auth.kind = "basic"`, `auth.prefix`, `auth.optional`.
  - A required or `{option}`-templated `base_url`, with `trim_slash`, `ensure_suffix`
    and `origin`.
  - `require_one_of` (alternative credentials), `public_operations`, `user_agent`.
  - `oauth`: client credentials, with an exclusive token alternative.
  - `error_classes`, `unknown_fields`, `transform_response`, `empty_json_body`,
    `query_style = "brackets"`.
  - Pointer lists and `non_empty` in `error_envelope`.
  - `glue`, a module in `providers/glue/` copied as `glue.lua`, which may export
    settings, base_url, headers, transform_input, error_envelope, classify_error,
    classify_success, transform_response and unknown_error.
  - Specs that use only the classic keys generate exactly as before.
- Runtime, in `lua/distilled/protocol/rest.lua`:
  - `rest.new{ provider = ... }` and `rest.compile_provider`.
  - Env lists, templates and OAuth token caching.
  - Envelopes, `classify_success` returning `true` (a 2xx answer read as a failure),
    and `now` in the `classify_error` info.
  - Operations on their own host follow `rest.route_base_url` (task 12's
    `route.server` / `route.base_url`).
- `credentials.from_env` takes a list of names.
- Providers:
  - 96 new specs in `providers/` (98 with neon and hetzner).
  - 23 glue modules in `providers/glue/`.
  - Each spec cites its TS sources.
- Docs: `docs/generating.md` section 4. `STATUS.md` has the "13 providers" section.

## Commands run (final, after merging main at c09d560)

```text
$ verify/dl fmt --check            # clean
$ verify/dl test
  lua: ok 1311 passed, 4 pending [Lua 5.5]
  luajit: ok 1311 passed, 4 pending [luajit]
  rex: ok 1299 passed, 8 pending [rex]
$ lua /tmp/t13/check.lua providers/*.lua         # every spec passes provider.validate
$ verify/dl models sync
$ for each providers/<lua>.lua:
    bin/distilled-lua package --models models/<pkg> --provider providers/<lua>.lua --out /tmp/t13/pkg/<lua>
  totals: 1016 models ok, 0 failed, 2 skipped (models.skip)
$ bin/distilled-lua generate (one model per spec, /tmp/t13/genone.sh): 98 ok
```

`spec/provider_spec.lua` covers three things:

1. Every file in `providers/` loads.
2. Strict validation, with a message for each mistake.
3. Generated fixture clients for every feature. This includes the error, empty-answer
   and OAuth refusal paths, and checks that a secret never appears in errors.

`spec/rest_spec.lua` covers the runtime directly: options, headers, envelopes, OAuth and
route hosts. No network is used; requests go through fixture responses.

## Files touched outside my list

- `lua/distilled/gen/writer.lua`: `init.lua`'s protocol and options are emitted here, not
  in `gen/init.lua`. Changes:
  - `provider = ...` for task-13 specs.
  - `error_classes`, pointer-list envelopes and `glue`.
  - The README options table.
  - Task 12's route-host options, which are declared for task-13 specs too.
- `lua/distilled/gen/types.lua`: the `Options` fields of task-13 specs.
- `lua/distilled/gen/provider_ext.lua` (new): it keeps the new keys out of
  `provider.lua`.
- `spec/gen_provider_spec.lua`: one line, because `kind = "basic"` is now valid.
- `lua/distilled/gen/init.lua`, beyond option emission:
  - Checks the `error_classes` and `public_operations` names.
  - Writes `glue.lua`.
  - An `error_classes` tag that a model also declares now uses the model's class.
  - `naming.operations` is no longer checked against a single model of a multi-model
    package (exa).

## Not written, and why (details in the survey)

- hetzner: owned by task 10.
- questrade: the refresh token travels in the token URL's query, and popen_curl puts URLs
  in process arguments. This needs a transport guarantee first.
- scaleway: needs `transform_input` glue for its region/zone defaults and a
  `classify_error` glue. The per-operation base URL now exists (task 12).
- slack: needs form-urlencoded bodies and the `ok: false` mapping by slug. It covers 36
  models.
- The 5 class-C packages: they need signing or another protocol (tasks 14, 16 and 23).

## Skipped or unverified

- No live API calls, per the rules. Each provider's behaviour is checked against its TS
  glue by reading the code, plus fixture tests for each feature. Not every provider has
  its own fixture exchange.
- Query-parameter auth was not added. No in-scope package authenticates its API calls
  with a query parameter; only questrade's token request uses the query string (see
  above).
- Clients are not generated or committed, as the brief says (the orchestrator runs
  `gen-all`).

## Open problems

- Multi-model packages whose models use different auth need `models.override` to carry
  `auth`, `options` and `headers`:
  - Affected: clerk, convex, digitalocean, e2b, exa, fly-io, mailchimp, onepassword.
  - Each spec's header comment says what the override must contain.
  - Today `models.override` takes `base_url` and `title`. A `base_url` override does
    reach the runtime data (`ext.override_base_url`).
- Stripe's `ApiVersion` per-call override is not modelled. Stripe-Version is a fixed
  header that a client option can override.
