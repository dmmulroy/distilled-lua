# Task 10: models sync, multi-model packages, generate-all, parity report

Read `tasks/10-parity-overview.md` first (decisions there are authoritative).

## Files you own

```text
bin/distilled-lua                 new subcommands / flags
lua/distilled/gen/init.lua        ONLY module-name / multi-model plumbing
lua/distilled/gen/provider.lua    ONLY keys for multi-model packages (models, per-model overrides)
verify/dl                         models, gen-all, gen-diff (multi-model), parity
verify/lib/gen_check.lua          multi-model support
verify/lib/parity.lua (new)       parity report
models/                           layout move (neon), .gitignore entries
.gitignore
docs/generating.md                the new workflow
spec/gen_layout_spec.lua (new)    and manifest
STATUS.md (section "10 layout")
```

## Requirements

1. `verify/dl models sync [pkg ...]` copies `../distilled/packages/<pkg>/.generated-specs/*.json`
   into `models/<pkg>/<model>.json` (all packages when none named; `--convert` re-runs the
   package's `scripts/convert.ts` first with `node --conditions=bun
   --experimental-transform-types`). Models are git-ignored; keep whatever conformance
   needs working (move `models/neon.json` to `models/neon/neon.json` and update every
   reference, or keep it committed, your call; say which).
2. Multi-model packages: the generator can emit a model as module `<lua>.<model>`
   (type prefix and README name follow), and a package index `clients/<lua>/init.lua`
   that lists the services and loads them lazily (`require("hetzner").servers` or
   similar; document it). Single-model packages stay `clients/<lua>/` like Neon.
   The provider spec may need `models = { skip = {...} }` and per-model overrides
   (e.g. a base URL per model); add the minimum, strictly validated.
3. `verify/dl gen-all [pkg ...]` regenerates every package that has a provider spec into
   `clients/`, in parallel, and reports per model: ok / generation error (first line).
   Models with no operations are skipped (Distilled skips them too).
4. `verify/dl gen-diff <pkg>` works for multi-model packages (all models).
5. `verify/dl parity` prints a table: package, TS op count (from
   `../distilled/packages/<pkg>/src/services/*.ts`, as in `tasks/notes/ts-op-counts.txt`),
   Lua op count in `clients/`, models generated / total, missing. Also writes
   `verify/features/parity.md` (committed). This is the progress meter for phase 2.
6. Prove it with two real multi-model packages without committing their clients unless
   their provider spec is trivial: e.g. `hetzner` (30 models) and `npm` (11). You may add
   `providers/hetzner.lua` and commit `clients/hetzner/` if it passes `gen-diff`
   (read `../distilled/packages/hetzner/src/{protocol,credentials,errors}.ts`).

Done means: proof bar, `dl gen-diff neon` still ok, `dl parity` output in
`tasks/10-layout.done.md`.
