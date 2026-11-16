# Task 11: schema gaps (nullable list items and map values, nullable rawResponse, type-name collisions)

Read `tasks/10-parity-overview.md` first. See `tasks/notes/smoke-results.txt` for every
failing model; reproduce with `sh tasks/notes/smoke-run1.sh <pkg>/<model>` (writes to
`/tmp/smoke`).

## Files you own

```text
lua/distilled/schema.lua, validate.lua, keys.lua, redact.lua   (schema node contract)
lua/distilled/gen/shapes.lua, gen/types.lua, gen/naming.lua
lua/distilled/gen/ops.lua    ONLY rawResponse output handling
docs/interfaces.md           schema section only
spec/schema_spec.lua, spec/validate_spec.lua, spec/gen_*_spec.lua (new cases), fixtures
STATUS.md (section "11 schema")
```

## Requirements

1. **Nullable list items and map values.** Distilled represents them (read
   `../distilled/packages/dev/src/codegen/` for how sparse/nullable members are emitted,
   and `../distilled/packages/core/src/schema*.ts` for decode/validate). Extend the node
   contract (e.g. `S.list(item, { sparse = true })` / nullable item) so decode keeps
   `json.null` items, validation accepts null there, key mapping and redaction walk them,
   and types.lua emits `T|nil` or similar. ~60 models fail on this today.
2. **Nullable rawResponse member** (anthropic beta_environments, discord, polymarket clob,
   vercel): emit it, matching Distilled's behaviour for an empty/absent body.
3. **Type-name collisions**: a model shape named `Client`, `Module`, or like a built-in
   error class (`NotFound`, `Forbidden`, ...) currently fails. Rename deterministically
   the way Distilled does if it has a rule (check its generator), otherwise with a
   documented suffix, and keep error classes distinct from shapes.
4. After your fixes, rerun the smoke script over every model in the failure list for your
   classes and report the before/after counts. Neon output must stay byte-identical
   (`verify/dl gen-diff neon`), conformance (`verify/dl conform neon --replay`) green.

Each fix gets a failing spec first on a small fixture model.
