# GraphQL clients (`distilled.graphql`, `clients/linear`, `railway`, `expo_eas`, `github/graphql`, `fly_io/graphql`)

A port of Distilled's GraphQL stack: the runtime `core/src/graphql.ts`, the generator
`dev/src/codegen/graphql-client.ts`, and each package's `graphql-transport.ts` and
`credentials.ts`. The input is the GraphQL type model that Distilled's
`scripts/convert-graphql.ts` writes: `packages/<pkg>/.generated-graphql/<pkg>.json`.

## Sub-features

- **Query algebra** (`lua/distilled/graphql.lua`). Every root and field is a lazy Query:
  - `Linear.viewer()` is a root. `q.email` is a field; reading a field the type lacks
    raises. `q.members({ first = 5 })` passes arguments; an unknown argument raises.
  - Combinators are free functions, so no GraphQL field name is shadowed:
    `gql.map(q, fn)`, `gql.filter(q, fn)`, `gql.flat_map(q, fn)`, `gql.of(v)`,
    `gql.fn(build)`.
  - A plan is any table holding Queries at any depth, mixed with plain values.
- **Compiling** (`graphql.compile(plan) -> compiled | false | nil, err`). All the fields a
  plan reads go into one selection forest, and the result is one document
  (`query Gql($v0: String!, ...) { ... }`, two-space indent, `mutation` for mutations).
  - The same field with the same arguments is one selection; with other arguments it
    becomes an alias (`projects_0: projects(first: $v1)`).
  - Relay connections select `edges { node { ... } }`, plus `pageInfo` when paged.
  - Variables are typed from the schema and numbered in visit order. Plan keys are sorted,
    and arguments follow the schema's declaration order. The cursor a page adds is bound
    last, as TS spreads `{ ...args, after }`.
  - These plans are refused with `GqlError` and the TS message:
    - a query and a mutation in one document;
    - an object with no sub-selection;
    - a plan nested deeper than `MAX_DEPTH` (48).
  - Secret argument values (`distilled.secret`) are sent plain in `variables`.
    `compiled.raw_variables` keeps them as secrets for span attributes.
- **Reading responses** (`graphql.result`, `graphql.evaluate`). After the POST, each value
  is read out of `data` by its alias path. Then:
  - map and filter run on the data; filter uses JavaScript truthiness;
  - `null` stays `json.null`;
  - `flat_map` runs its callback; a plan it returns runs as a new request;
  - a callback that raises after the POST becomes an `SdkError`.
- **Sensitive fields** (the model's `sensitive` marks: Railway has 13, Fly's
  `AddOn.password`, ...) decode as secrets. This holds through nested objects, aliases,
  connections, whole rows, leaf roots and `GraphQLFailure.data`. A sensitive JSON scalar
  becomes one secret holding the whole decoded value.
- **Errors.** Each `errors[]` entry is classified against matchers: the root's own errors
  when the entry has a path, plus the SDK's global errors.
  - Scores: `code` = 1, `message` = 4, `messageIncludes` = 2. `extensions.code` is read
    first, then `extensions.errorCode`, then the top-level `type` (GitHub).
  - A tie between different tags gives `UnknownGraphQLError`, with `err.coordinate`.
  - Entries that all share one tag return the first entry itself. Mixed tags give
    `GraphQLFailure`, with `err.errors` and the partial `err.data`.
  - Instances carry:
    - `code`, `status`, `path` and `locations` (malformed ones are dropped);
    - `retry_after` in seconds (from `Retry-After`);
    - `server_trace_id` (from `extensions.traceId` or the top-level `traceId`);
    - the `distilled.errors` categories (`NotFoundError`, `throttling`, ...).
  - A response with no data object and no errors, a body that is not JSON, or an HTTP
    error without GraphQL errors is a `GraphQLTransportError`. Its message is the
    provider's (`Linear HTTP 502 returned a non-GraphQL response`, `Eas HTTP 401:
    <detail>`). A network failure is the cause of a `... GraphQL HTTP request failed`.
- **Retries** (`graphql.is_retryable`, `graphql/client.lua`). Queries are retried at most
  5 times, 200 ms doubling, and only while every error is retryable (a retryable class,
  or a transport error with no status, 429 or 5xx). Mutations are never retried.
  `retry = "none"` or `{ max_retries = n }` replaces the policy.
- **Relay pagination** (`graphql.pages(q, execute, kind)`, `client:pages(q)`,
  `client:items(q)`). An iterator in the `distilled.paginate` style: callable, with
  `it.err`, `:collect([limit])`, `:close()` and `it.pages`.
  - Each page sets `after` to the previous `endCursor`, starting from the query's own
    `after`. It stops when `hasNextPage` is false.
  - A cursor that does not advance (the same cursor, or null with more pages) fails with
    `GraphQLPaginationError`, and that page's items are not handed out.
  - Paging something that is not a connection, or a root with no `after` argument, is a
    `GqlError`.
- **Client** (`graphql/client.lua`, `M.define`). It is built on `distilled.client`, so the
  common options (`host`, `transport`, `retry`, `deadline_s`, `tracing`, `with`, `close`)
  behave as in REST clients. Methods: `run(plan, ...)`, `pages`, `items`, `compile`.
  - The transport spec is copied from each `graphql-transport.ts`: the endpoint
    (base + path, GHES `/v3` stripped, Fly's fixed URL), auth (header shape, Bearer or
    bare, env variables in precedence order, trimmed, empty means unset), `User-Agent`,
    `Accept`, and HTTP detail extraction.
  - With no credential, a run returns the provider's `ConfigError` message.
- **Telemetry.** One span per document, as in `graphql-telemetry.ts`:
  - The name is `<Prefix>.<root>` for a single root, else `<Prefix>.query` or
    `<Prefix>.mutation`.
  - Attributes: `graphql.operation.type`, `graphql.operation.name`, `rpc.*`, the SDK's
    argument attributes (never a secret), and response header and status attributes.
  - A W3C `traceparent` is sent; a failed run carries `err.trace_id`.
- **Generator** (`lua/distilled/gen/graphql.lua`, `bin/distilled-lua generate-graphql`, or
  auto-detected by `package`). It turns the model plus a provider spec into
  `init.lua`, `schema.lua`, `types.lua` (LuaLS classes, Lua keywords quoted) and
  `README.md`.
  - Output is deterministic and stylua-clean.
  - Bad specs or models fail at generation time.
  - A mutation whose name collides with a query gets a `Mutation` suffix, as in
    `graphql-client.ts`. Roots that return a root type (GitHub's `Query.relay`) are
    skipped.
  - The schema is stored as long-bracket text blocks, one per type, parsed on first use.

## How a user reaches it

```lua
local Linear = require("linear") -- or "railway", "expo_eas", "github.graphql", "fly_io.graphql"
local gql = require("distilled.graphql")
local client = Linear.new({ host = require("distilled.host.popen")() }) -- $LINEAR_API_KEY

local me = Linear.viewer()
local value, err = client:run({
  email = me.email,
  teams = gql.map(Linear.teams({ first = 50 }), function(team)
    return { id = team.id, key = team.key }
  end),
})
if not value then
  return nil, err -- err.tag: LinearRateLimited, GraphQLFailure, GraphQLTransportError, ...
end

for issue in client:items(gql.map(Linear.issues({ first = 100 }), function(i)
  return i.title
end)) do
  print(issue)
end

local created = client:run(Linear.issueCreate({ input = { teamId = "T", title = "x" } }).success)
```

Names stay as the schema spells them (`issueCreate`, `avatarUrl`), both in Queries and in
the values a run returns. That mirrors the TS SDK, where the GraphQL names are the API.
The SDK modules are read-only: `Linear.errors.<Tag>`, `Linear.roots()`,
`Linear.type(name)` and `Linear.new(opts)`.

Generating:

```sh
bin/distilled-lua generate-graphql --model models/linear/graphql/linear.json \
  --provider providers/linear.lua --out clients/linear
bin/distilled-lua package --models models/github --out clients/github   # REST + graphql/
```

## Driving it with `dl`

- `verify/dl test graphql` runs the three specs on all three runtimes (88 cases):
  - `spec/graphql_runtime_spec.lua`: the cases of core `graphql.test.ts`
    (`Query.fn`, connections, nested connections, arguments as variables, `Query.map` on
    objects, sensitive fields, secret arguments, malformed responses), plus
    classification, compiling, flat_map, callbacks and pagination.
  - `spec/graphql_client_spec.lua`: the generated clients over the scripted transport.
    It checks each provider's URL, auth headers and env precedence, the `ConfigError`,
    retries (sleeps asserted), the no-retry rule for mutations, transport failure
    messages, GitHub's `type` code, secrets kept out of errors, pages and items, and
    spans.
  - `spec/graphql_conform_spec.lua`: request conformance.
    `verify/conform/node/graphql_requests.mjs` runs the 24 plans of
    `spec/fixtures/graphql/cases.json` through Distilled's TS SDKs (Linear, Railway,
    Eas, GitHub, Fly) with a recording transport, into
    `spec/golden/graphql/requests.json`. The spec builds the same plans in Lua and
    compares the query text, variables and operationName of every request, including
    second pages and a plan TS refuses. Regenerate the golden file with:

    ```sh
    node --conditions=bun --experimental-transform-types --no-warnings \
      verify/conform/node/graphql_requests.mjs > spec/golden/graphql/requests.json
    ```
- `verify/dl gen-diff <linear|railway|expo_eas|github|fly_io>` regenerates and compares,
  checks stylua, and runs `verify/lib/graphql_check.lua` on lua, luajit and rex. The
  check builds and compiles every root, parses every type, and checks the error classes.
- `verify/dl models sync` copies `.generated-graphql/<pkg>.json` to
  `models/<pkg>/graphql/`. Add `--convert` to rerun `convert-graphql.ts` first.

## Load time (measured)

`require` of a generated client takes about 0.1 ms once the runtime is loaded, and about
4 ms for the first, which loads the runtime. `roots()` builds every root in 1–3 ms on
lua and luajit, and 2–12 ms on rex. GitHub's 1,080 types parse in full in 10.5 ms on
lua 5.5 and 7.3 ms on luajit; a normal run parses only the types it touches.

## Gotchas

- Lua tables have no key order, so the variable numbering follows the sorted plan keys
  and the schema's argument order. The conformance driver visits TS plans in the same
  order. Its spellings differ from a TS caller's object order, but the meaning does not.
- `gql.map` on a connection gives a list of nodes. A field read straight off a
  connection (`Linear.teams().id`) is a list too, but it cannot be paged: page a `map`.
- `flat_map` inside `map`/`filter` is refused (`GqlError`), as in TS.
- An empty argument table is no arguments (TS treats `field({})` as a second selection).
- github and fly_io are mixed packages. Their GraphQL clients are
  `clients/<pkg>/graphql/`, with the module `<pkg>.graphql` and the spec
  `providers/graphql/<pkg>.lua`. The REST specs belong to task 13.
