# Task 16: GraphQL clients (done)

## What was built

- **Runtime.** It ports core `graphql.ts`.
  - `lua/distilled/graphql.lua`: the lazy Query algebra and combinators (`map`, `filter`,
    `flat_map`, `of`, `fn`), the compiler, response reading, error classification,
    `is_retryable` and Relay `pages`.
    - The compiler builds the selection forest, aliases, typed variables `$vN` and the
      document text.
    - Response reading handles alias paths, `json.null`, partial data and sensitive
      fields as secrets.
    - Classification uses the matcher scores (code 1, message 4, messageIncludes 2), and
      ties give `UnknownGraphQLError`. Mixed tags give `GraphQLFailure`.
    - Relay `pages` has a non-advancing cursor guard.
  - `lua/distilled/graphql/client.lua`: a GraphQL client on `Client.define`, with `run`,
    `pages`, `items` and `compile`.
    - The transport handles the endpoint, auth, User-Agent, traceparent and HTTP detail.
    - Queries are retried (at most 5, 200 ms doubling); mutations are never retried.
    - It makes one document span (`<Prefix>.<root>` or `<Prefix>.<kind>`).
  - `lua/distilled/graphql/sdk.lua`: the SDK module that generated clients build, with a
    lazily parsed schema.
- **Generator.**
  - `lua/distilled/gen/graphql.lua` turns a model plus a provider spec into `init.lua`,
    `schema.lua`, `types.lua` and `README.md`. The output is deterministic, stylua-clean,
    and bad input fails early.
  - `bin/distilled-lua generate-graphql` runs it, and `package` auto-detects
    `models/<pkg>/graphql/<pkg>.json`.
- **Provider specs** (from each `credentials.ts` and `graphql-transport.ts`):
  `providers/linear.lua`, `railway.lua`, `expo_eas.lua`, `graphql/github.lua`,
  `graphql/fly_io.lua`.
- **Clients** (generated, committed): `clients/linear`, `clients/railway`,
  `clients/expo_eas`, `clients/github/graphql`, `clients/fly_io/graphql`.
- **Verify.**
  - `verify/dl` additions:
    - models sync of `.generated-graphql` (`--convert` reruns `convert-graphql.ts`);
    - GraphQL packages in `spec_packages`;
    - the gen-diff hook running `verify/lib/graphql_check.lua` on all three runtimes.
  - The check builds and compiles every root, parses every type, and checks the error
    classes.
- **Tests.**
  - `spec/graphql_runtime_spec.lua` (42): ports core `graphql.test.ts`.
  - `spec/graphql_client_spec.lua` (22): per-provider requests, credentials, retries,
    failures, pages and spans over the scripted transport.
  - `spec/graphql_conform_spec.lua` (24): request conformance.
    `verify/conform/node/graphql_requests.mjs` records what the TS SDKs send for the 24
    plans in `spec/fixtures/graphql/cases.json` into
    `spec/golden/graphql/requests.json`. The spec compares query text, variables and
    operationName, including second pages, secret arguments and one plan TS refuses.
- **Docs:** `verify/features/graphql.md`, each generated README, and STATUS.md section 16.

## Commands run (after `git merge main`, merge commit fbe81cf)

```text
$ verify/dl doctor
doctor: ok
$ verify/dl test
  lua: ok 1308 passed, 4 pending [Lua 5.5]
  luajit: ok 1308 passed, 4 pending [luajit]
  rex: ok 1296 passed, 8 pending [rex]
$ verify/dl test graphql          (before the merge; unchanged by it)
  lua: ok 88 passed  luajit: ok 88 passed  rex: ok 88 passed
$ verify/dl fmt --check           exit 0
$ verify/dl gen-diff linear|railway|expo_eas
gen-diff linear: ok
gen-diff railway: ok
gen-diff expo-eas: ok
  (each: 494 / 445 / 145 roots built, all types parsed, on lua, luajit and rex)
$ bin/distilled-lua generate-graphql --model models/<pkg>/graphql/<pkg>.json \
    --provider providers/graphql/<p>.lua --out /tmp/gq_<p> --quiet; diff -r ...
github graphql: identical, stylua ok, check ok on lua/luajit/rex (308 roots, 1080 types)
fly_io graphql: identical, stylua ok, check ok on lua/luajit/rex (125 roots, 250 types)
$ node --conditions=bun --experimental-transform-types --no-warnings \
    verify/conform/node/graphql_requests.mjs > /tmp/req.json; cmp ... spec/golden/graphql/requests.json
golden-reproducible
```

Load time, as measured by `graphql_check`:

| | load | parse every type |
| --- | --- | --- |
| GitHub, lua 5.5 | 2.2 ms | 10.4 ms |
| GitHub, luajit | 2.3 ms | 7.3 ms |
| GitHub, rex | 6.0 ms | 33.5 ms |
| linear, rex | 6.1 ms | 20.8 ms |

## Skipped, and why

- `verify/dl gen-diff github` and `gen-diff fly_io` stop with "no provider spec". The REST
  specs `providers/github.lua` and `fly_io.lua` are task 13's and are not on main yet.
  I verified the GraphQL halves directly instead (regenerate, `diff -r`, stylua, check on
  all three runtimes). Once task 13 merges, `gen-diff` covers both halves through the
  `package` auto-detect.
- No live API calls; the tests use only the scripted transport.
- Subscriptions: the TS SDKs generate none either.

## Open problems

- `verify/features/README.md` (not mine) should list `graphql.md`.
- STATUS.md on main has three leftover `||||||| abf4e89` merge markers from earlier merges.
  They are not mine and I left them.
- The 4 extra pending cases on rex are in specs outside this task. None are GraphQL specs.
