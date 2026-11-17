# Task 26: generate and commit every REST client (gen-all), to parity

Read `tasks/10-parity-overview.md`, `STATUS.md` (all sections) and
`docs/providers-survey.md` (task 13) first. Tasks 10-16 are merged into main: multi-model
packages, `verify/dl models sync`, `gen-all`, `gen-diff`, `parity`, schema and trait gaps,
and ~95 provider specs in `providers/`. Nothing but `clients/neon` and `clients/hetzner`
is generated and committed yet. You make that happen for every provider spec.

Running in parallel (do not take their files): 17 aws, 18 big-models (emission for very
large models, e.g. infisical's service.lua exceeds LuaJIT's constant limit), 19
cloudflare, 20 azure, 21 gcp, 22 tencentcloud, 23 grpc (modal/boxd/e2b/namespacelabs),
24 pk-crypto, 25 s3, 27 provider-gaps (slack, scaleway, questrade, per-model auth
overrides).

## Files you own

```text
clients/<pkg>/ for every package with a REST provider spec (not aws, s3, cloudflare,
  azure, gcp, google_workspace, tencentcloud, modal, boxd, e2b, namespacelabs, slack,
  scaleway, questrade, nor the per-model-auth packages task 27 lists, until 27 lands)
providers/*.lua    ONLY fixes the generation proves necessary (say which in STATUS)
lua/distilled/gen/* small generator fixes found by gen-all (each with a fixture spec;
  keep them minimal: other agents edit gen/ too)
verify/features/parity.md (regenerated)
STATUS.md (section "26 clients")
```

## Requirements

1. `verify/dl models sync`, then `verify/dl gen-all`. For every failing model, fix the
   cause (generator bug -> fix + spec; provider spec bug -> fix; a gap owned by a running
   task -> record it in STATUS and skip that model with `models.skip` and a comment).
2. For every package: `verify/dl gen-diff <pkg>` must pass (generation identical on lua
   and luajit, stylua clean, loads and builds every request on lua, luajit and Rex).
   Commit each package's client separately (`clients: <pkg>`), and push your branch after
   each few packages (`git push origin task-26`).
3. Models too large to load (task 18's problem): skip them with a STATUS note; regenerate
   them after `git merge main` brings task 18's fix.
4. Run `verify/dl parity` at the end and commit `verify/features/parity.md`; the done
   file lists every package below 100% parity and why.
5. Repository size: report the total size of `clients/` and the largest packages.
