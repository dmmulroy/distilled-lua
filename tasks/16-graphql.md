# Task 16: GraphQL clients (linear, railway, expo-eas; GraphQL parts of github and fly-io)

Read `tasks/10-parity-overview.md` and `STATUS.md` (sections 10-15) first.

Distilled's GraphQL packages are not Smithy: `scripts/convert.ts` writes
`../distilled/packages/<pkg>/.generated-graphql/<pkg>.json` (a GraphQL type model with
patches), and `../distilled/packages/dev/src/codegen/graphql-client.ts` compiles it into
`src/graphql.ts` (TypeMeta + `Linear.viewer`, `Linear.teams`, ...) and
`src/graphql-telemetry.ts`. The runtime is `../distilled/packages/core/src/graphql.ts`
(selection building, variables, errors, pagination, ...) plus each package's
`src/graphql-transport.ts` and `credentials.ts`. github and fly-io have both REST (Smithy)
and GraphQL parts.

## Files you own

```text
lua/distilled/graphql.lua (+ lua/distilled/graphql/*.lua)   runtime (port of core graphql.ts)
lua/distilled/gen/graphql.lua (+ gen/graphql/*.lua)         generator for GraphQL models
bin/distilled-lua           ONLY a `generate-graphql` (or auto-detected) path
verify/dl                   ONLY models sync for .generated-graphql and gen-all/gen-diff hooks
                            for GraphQL packages (keep edits small; task 10 owns the rest)
providers/linear.lua, railway.lua, expo_eas.lua (new); GraphQL keys in github/fly_io specs
clients/linear/, clients/railway/, clients/expo_eas/ (generated, committed)
spec/graphql_*_spec.lua, verify/features/graphql.md
STATUS.md (section "16 graphql")
```

## Requirements

1. Port the runtime semantics of core `graphql.ts` that the generated SDKs use (read its
   tests in `../distilled/packages/core/test/`): how a call names its selection, how
   variables are typed, errors (GraphQL `errors[]` with extensions, partial data), Relay
   connection pagination, retries, sensitive fields, telemetry names.
2. Design the Lua surface to mirror the TS one (`linear:viewer{ select = ... }` or
   whatever matches `graphql-client.ts`'s output most closely); document it in
   `verify/features/graphql.md` and the generated README. Lua idioms: values or
   `nil, err`, snake_case where the TS SDK maps names.
3. Generator: GraphQL model -> `clients/<pkg>/` (init.lua, a schema/types data module,
   types.lua, README.md). Deterministic, stylua-clean, loads in lua, luajit and Rex.
   Large schemas (github's is ~40k lines of TS) must load quickly: measure.
4. Provider specs from each package's `credentials.ts` / `graphql-transport.ts` (auth
   header shapes, env variables, endpoints).
5. Tests: request bodies (query text + variables) for a sample of operations compared with
   what the TS SDK sends (a Node script, as `verify/conform/node/` does for Neon), error
   and pagination paths against the fixture transport.
