# Conformance against Distilled (`dl conform`)

Distilled's TypeScript runtime is the oracle. For the same operation and the same input
or canned response, the generated Lua client must do what Distilled's generated Neon
client does, or the difference must be listed below with its reason.

## Sub-features

- **Cases** (`verify/conform/cases.lua`, seeded, identical on every run and runtime):
  - requests: per operation `min` (required members), `full` (every member, nested
    optional members, depth 5) and `rand1..3` (awkward values: percent-encoding, UTF-8,
    empty strings, 0, `false`, empty arrays and objects, lists in query members, explicit
    nulls on nullable members, `{ "$secret": v }` on sensitive members, an undeclared
    `zz_extra` key in `rand3`), then hand-written edge cases
    (`cases/neon_requests.lua`: `.`/`..`/empty/missing labels, `1e21` and `1e-6` in a
    query, NUL bytes, nulls and undeclared keys in nested bodies). 902 cases.
  - responses: per operation a success body built from the output schema (`ok-min`,
    `ok-full`, `ok-rand`, plus `ok-min-strict` and `ok-full-strict`; raw-bytes outputs get
    binary bodies), then `cases/neon_responses.lua`: empty, 204, non-JSON, null, array,
    truncated and whitespace bodies; unicode escapes and odd numbers; 202 / 200-for-201;
    secrets in output (`create_api_key`) including a non-JSON body for a secret-holding
    output; lenient / additional / strict validation with extra keys, wrong types and
    missing members; every declared error (400, 403, 404, 409, 422) and odd error bodies;
    the status map and fallbacks on an operation with no declared errors (300 to 599);
    `Retry-After` as seconds, zero, fraction, negative, garbage, IMF-fixdate (future and
    past), RFC 850, asctime and huge. 977 cases.
  - flows (`cases/neon_flows.lua`): retry sequences (5xx, 429 with and without hints,
    hint over the cap, exhaustion, non-retryable statuses, transport failures, POST and
    DELETE, `none` / `throttling` / `transient` policies) and cursor pagination
    (`items` and `pages`, `pagination.cursor` and `pagination.next`, repeated cursor,
    start cursor, empty pages, missing items key, failure and retry on page 2, numeric
    cursor). 36 cases. Compared: every request (method, URL, time on the fake clock in ms)
    and the result, including the items a traversal produced before it failed.
  - members: every operation's top-level input members (name, required) in the Lua
    service against Distilled's input schema, so a member the generator dropped shows up
    even though no case can send it.
- **Node side** (`verify/conform/node/*.mjs`), Distilled imported by path, nothing under
  `../distilled` modified: `API.encodeRequest(op, input)` with Neon's protocol and fixed
  credentials (requests); the operation over a stub `HttpClient` with the Neon retry
  service set to never (responses); flows with the default/`throttling`/`transient`
  policies. A `TestClock` at 1700000000 s; `Date.now` pinned to it (Distilled's
  `retry-after.ts` reads wall time) and `Math.random` to 0.5 (as Distilled's own retry
  tests do); a fresh default budget per flow.
- **Lua side** (`verify/conform/check_*.lua`): the generated client from `clients/neon`
  with the same credentials and base URL, a capturing or scripted transport, a fake clock
  at the same epoch, `random` pinned to 0.5 and a fresh budget per case.
- **Comparison** (`verify/conform/diff.lua`): method; URL path as raw bytes; query
  content as decoded pairs (a multiset), query order and query encoding reported
  separately; meaningful headers (content-type, authorization, member-bound headers);
  bodies as parsed JSON when the content type is JSON, else bytes; outcomes as JSON
  (secrets as `{ "$redacted": value }`, bytes as `{ "$bytes_b64": ... }`; errors as tag,
  categories, retryable, throttling, status, code, message, retry_after, body).
- **Replay**: the reference dumps are committed (`verify/conform/ref/neon/*.jsonl`), so
  `--replay` and `spec/conform_replay_spec.lua` compare all three runtimes without Node.

### Intended differences (each normalised explicitly in `verify/conform/intended.lua`)

| Difference | Lua | Distilled | Why |
| --- | --- | --- | --- |
| Missing path label | `InvalidInput` before sending | sends `/projects/{project_id}` literally | Sending the placeholder addresses the wrong resource; failing early is the library's rule |
| `err.status` on typed and status-mapped errors | always the HTTP status | absent (the classes have no status field) | The plan's error shape has `status` on every HTTP error |
| `err.code` | the wire code, or nil | `0` on generated classes (a `Number` field: a string code does not fit); absent on built-in status classes | Keep what the server said; `0` is not a code |
| Parse error message | says what failed (`cannot decode the response of GetProject: Expected object ... at ["project"]`) | `""` (detail only in `cause`) | A message Rex shows must say something |
| Transport failure | tag `TransportError`, category `NetworkError`, the transport's message | Effect's `HttpClientError`, no category | No Effect in Lua; the category makes it matchable |
| asctime `Retry-After` | read as GMT (RFC 9110 5.6.7) | `Date.parse` reads it in the machine's local zone (here 5 h off) | Distilled's value depends on the machine; RFC says GMT |

Not compared (skipped, with the reason printed): the multipart operation
`create_project_branch_function_deployment` until `tasks/08-multipart.done.md` exists.
No "transient until the budget runs out" flow: Distilled's transient policy has no budget
and never stops.

## How a user reaches it

It is a verification tool, not an API. A user sees its result as "the Lua client sends
and understands exactly what Distilled's does", and the intended differences above are
documented in `docs/usage.md`.

## Driving it with `dl`

```sh
verify/dl conform neon            # cases -> Node dumps -> diff under lua (needs ../distilled installed)
verify/dl conform neon --replay   # no Node: diff the committed dumps under lua, luajit, rex
verify/dl conform neon --replay --runtime rex --only flows
DL_CONFORM_VERBOSE=1 lua verify/conform/compare.lua "$PWD" neon   # also list intended diffs
verify/dl test conform_           # differ/rules specs + replay, in all three runtimes
```

`dl live` is the last mile, against the real API (opt-in, never in tests):

```sh
NEON_API_KEY=... verify/dl live neon list_projects limit=5    # GET only; span tree on stderr
verify/dl live neon delete_project project_id=p1 --write      # anything else needs --write
```

Values parse as JSON when they can (`limit=5` is a number), else they are strings. Exit
0 ok, 1 the call failed, 2 misuse (unknown op, a non-GET without `--write`), 3 skipped:
no credentials, so the call failed with `ConfigError` before sending anything. With no
key on this machine the live run is skipped; pointing `NEON_API_BASE_URL` at `dl serve`
proves the wire path end to end (`verify/dl serve run sh -c 'NEON_API_KEY=x
NEON_API_BASE_URL=$DL_SERVE_URL/live verify/dl live neon list_projects'` -> the server's
404, exit 1).

Output: one `MISMATCH <category> <case id> (case: verify/conform/cases/neon/<file> line N)`
per mismatch with `field: distilled <value> | lua <value>` lines, then a summary per
category; exit 1 (an error in Rex) on any mismatch.

Last run (task 07): members 178/178, requests 897 match + 5 skipped (multipart), responses
972 match + 5 skipped, flows 36/36; 0 mismatches; 79 cases carry intended differences.

## Gotchas

- Node needs `--conditions=bun --experimental-transform-types` (Distilled's sources use
  TypeScript parameter properties, which strip-only mode rejects). `dl conform` passes
  them.
- Distilled's `Retry-After` HTTP-date parsing uses `Date.now()`, not the Effect clock:
  without pinning it, date hints come out as 0 under a `TestClock`.
- An operation whose retry never ends (transient policy, always failing) hangs the Node
  side: `runVirtual` only advances the clock one hour and then waits for the fiber.
- Regenerate the dumps (`dl conform neon` without `--replay`) after changing cases or
  updating Distilled, and commit `verify/conform/cases/` and `verify/conform/ref/`
  together; otherwise replay reports `(no reference)`.
- Case inputs are JSON: `{ "$secret": "v" }` is a secret and JSON null is `json.null` /
  `null` on both sides. Generated inputs are what the Lua schema allows; the `members`
  category is what catches a schema that lacks a member.
