# Task 11 (schema): done

Branch `task-11`. Commits `4d6fec9..` (schema, gen x3, a types.lua layout fix, docs, status).

## What was built

1. **Nullable nodes** (Distilled's `S.NullOr`). Any schema node may carry `nullable = true`;
   `S.nullable(node)` returns a marked copy, and `schema.node_nullable(node, registry)` reads
   the flag through refs (it is also true for `null`/`unknown` nodes). `validate.check`
   accepts `json.null` at such a node in every mode. A member whose node is nullable counts
   as a nullable member. `keys` and `redact` needed no code change: they already passed
   null through. Specs now pin that behaviour (rename in both directions, sensitive members
   of sparse items wrapped, null stays null).
2. **Sparse lists and maps**: `gen/shapes.lua` `shapes.element` gives a list item or map
   value its member traits, as Distilled's list/map branch does: `S.sensitive` for
   sensitive, then `S.nullable` for nullable. types.lua writes `(T|distilled.Null)[]` and
   `{ [string]: T|distilled.Null }`.
3. **Nullable rawResponse**: `ops.output` emits `output = S.nullable(<target>)` with
   `output_raw = true` (Distilled: `S.NullOr(target).pipe(rawResponseRoot)`). The node keeps
   the target's type, so `protocol/rest.lua` is unchanged. An empty body decodes as `""` for
   a string target and `{}` otherwise, as in Distilled (`resolveNode` collapses NullOr). A
   JSON `null` body decodes to `json.null` in lenient, additional and strict mode
   (protocol-rest.test.ts "a 200 response whose body is JSON null returns null, in strict
   mode too"). types.lua returns `(T|distilled.Null)?`.
4. **Type-name collisions**: Distilled has no rule for this. TypeScript has no Client type,
   and its error classes take the error shapes' own names, while our types.lua appends
   `Error`. So the rule is ours, in `naming.type_names`: a shape whose LuaLS type name is
   one the client uses (`Client`, `Options`, `Module`, `<Tag>Error`) becomes `<Name>Shape`,
   then `Shape2` and so on while the name is taken. The ids are sorted, so the result is
   deterministic. Registry keys, struct names and `S.ref` names keep the model's names; only
   types.lua changes. Error class types stay as they were. `gen/init.lua` sets
   `ctx.type_names` where it used to fail generation.
5. A finding from the newly generating models: types.lua now breaks a `function
   Client:<name>(input) end` line longer than 100 columns the way stylua does, measured
   with stylua 2.6 (the cut-over is at more than 100 columns). Six of the newly generating
   models failed `stylua --check` without it.
6. `docs/interfaces.md` (schema section) and `STATUS.md` (section 11) are updated.

Each fix got a failing spec first, checked by reverting the library change and running
the spec. Results: schema_spec describe failed; gen_shapes_spec failed with "nullable map
values have no representation"; gen_ops_spec failed with "a nullable rawResponse member is
not supported" and with the four "its type name" errors; gen_output_spec failed 2 tests.

New spec cases: `spec/schema_spec.lua` ("schema: nullable nodes (S.NullOr)", 9 cases),
`spec/gen_shapes_spec.lua` (sparse list and map, replacing the old refusal test),
`spec/gen_ops_spec.lua` ("gen.ops: nullable rawResponse output", 5 cases, including
end-to-end calls through the generated client with `distilled.testing.host`, and the
type-name case replacing the old refusal test), `spec/gen_naming_spec.lua` (type_names),
`spec/gen_output_spec.lua` (long method name, stylua check of types.lua too).

## Proof

```text
$ verify/dl doctor
...
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
== summary
  lua: ok 1062 passed, 4 pending [Lua 5.5]
  luajit: ok 1062 passed, 4 pending [luajit]
  rex: ok 1055 passed, 7 pending [rex]
```

(The baseline before this task was 1048 passed with 6 pending. Two of those pendings,
"verify/tmp is not writable", went away once `verify/tmp` existed in this fresh worktree.)

```text
$ verify/dl gen-diff neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; ...
ok gen-check luajit: 649 shapes, 835 refs resolved, 178/178 ops built, ...
ok gen-check rex: 649 shapes, 835 refs resolved, 178/178 ops built, ...
gen-diff neon: ok

$ verify/dl conform neon --replay        (each of lua, luajit, rex)
  members    178 cases:  178 match (0 with intended differences), 0 mismatch, 0 skipped
  requests   904 cases:  904 match (1 with intended differences), 0 mismatch, 0 skipped
  responses  977 cases:  977 match (67 with intended differences), 0 mismatch, 0 skipped
  flows       36 cases:   36 match (11 with intended differences), 0 mismatch, 0 skipped
conform: ok
```

### Smoke, before and after

Failure list: the models in `tasks/notes/smoke-results.txt` whose message names one of
this task's classes (`nullable list items`, `nullable map values`, `nullable rawResponse`,
`its type name`): **90 models**. The messages there are cut at 300 characters, so the
per-class counts are lower bounds: 54 / 50 / 14 / 15.

```text
$ grep FAIL tasks/notes/smoke-results.txt | grep -E "nullable (list items|map values)|nullable rawResponse|its type name" \
    | awk '{print $2}' > /tmp/t11-list.txt                      # 90
$ cat /tmp/t11-list.txt | xargs -P 6 -n 1 sh tasks/notes/smoke-run1.sh > /tmp/t11-after.txt
$ grep -c ^OK /tmp/t11-after.txt
90                                    # before: 0 of 90; after: 90 of 90
```

- All 267 previously failing models, rerun: 90 OK, 177 still fail. The full logs of the
  177 (`/tmp/smoke-distilled-lua-11/log_*.txt`) do not name any of this task's classes.
  They fail on baseUrl/server/accept, streaming, errors#bodies prelude, pagination, a
  missing label, no operations, GraphQL, and the stripe crash below.
- All 939 previously passing models, rerun: 939 OK (no regression).
- Smoke total: **1,029 of 1,206** (was 939).
- The 90 outputs go further than generation. `verify/lib/gen_check.lua` loads each one,
  resolves every ref and builds a request for every op. It passes for 89 of 90 under lua,
  luajit and rex. `stylua --check` passes on all 90 output directories.

## Skipped / not verified

- The LuaLS annotations (`distilled.Null`, `<Name>Shape`) were checked by reading only:
  lua-language-server is not installed. types.lua still compiles as Lua, and a spec checks
  that.
- The only Distilled differential (conformance) is Neon's, and Neon has none of these
  shapes. The nullable-root behaviour was checked against the Distilled test it ports,
  not against Node output.

## Open problems (also in STATUS.md, section 11)

- `gen/init.lua` is not in my file list; its type-name block was changed (10 lines, away
  from task 10/13's parts).
- stripe/stripe crashes in `ops.output` (task 12's part of `gen/ops.lua`): 4 operations
  have a prelude output (`smithy.api#Unit`, `smithy.api#Document`), so `def` is nil.
- starburst-galaxy/live_table: `gen_input` cannot synthesize `update_live_table_schema`'s
  input (its required members recurse), so gen_check builds 5 of 6 ops. This is a limit of
  the test synthesizer, not a generation problem.
