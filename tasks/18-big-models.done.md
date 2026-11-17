# Task 18: very large models: done

## What was built

- **Split layout for large services** (`lua/distilled/gen/writer.lua`). A service whose
  single `service.lua` would pass `writer.SINGLE_FILE_MAX_BYTES` (512 KB) or
  `SINGLE_FILE_MAX_CONSTANTS` (20,000) becomes `service.lua` (errors, shape index, lazy
  registry, op loader) plus `service/shapes_NNN.lua` (~128 KB / at most 4,000
  constants each, loaded on first use of one of their shapes), `service/ops_NNN.lua`
  (all loaded by service.lua) and, only when errors are big, `service/errors_NNN.lua`.
  Shapes are packed in the order operations reach them (depth-first), so a call
  usually loads one file. Small models are byte-identical (Neon, all 30 Hetzner models).
- Generation fails early when one statement passes `writer.MAX_CONSTANTS` (60,000,
  LuaJIT's limit is 65,536) or `writer.MAX_DEPTH` (100 nesting levels).
- `gen/emit.lua`: `emit.scan` (literals, tables, depth, refs; explicit stack) and
  `emit.long_string`. `gen/init.lua`: `files.dirs`, `writer.service` errors propagate.
- `bin/distilled-lua` (outside my list, needed): creates `files.dirs`, removes a generated
  client's stale `service/` before writing.
- `verify/lib/gen_check.lua`: on a split service, checks nothing is loaded by `require`,
  an unknown name is nil, every shape file loads and each shape resolves through the
  registry to the same node; then the usual ref/op checks over every shape.
- Measurement tools: `verify/lib/lua_limits.lua` (compiler limits per runtime),
  `verify/lib/load_bench.lua` (require/call time and heap), `verify/lib/big_models.sh`
  (before/after report driver, RSS via `/usr/bin/time -l`), `verify/lib/bench_sanitize.mjs`
  (patches models other tasks cannot generate yet, for measuring only),
  `verify/lib/big_synth.lua` (synthetic Smithy models of any size).
- `spec/gen_big_spec.lua` (15 cases): one file vs split, determinism, locality, lazy
  loading (no shape file on require, one per lookup, unknown names), calls through a split
  client (success, a 404 error, strict output validation), a missing shape file raises,
  errors files, constant-based split, `--ops`, early failures, README/init/types
  unchanged by the layout, long strings, scan; and the CLI: `package` with a split model
  next to a small one plus gen_check on the index, `generate` removing stale chunk files,
  `--ops` back to one file.
- `verify/features/generator.md`: "Large models" (layout, contract, limits table, the
  before/after tables). `STATUS.md` section 18 (contract update for `service.shapes`).

## Results

Limits and the cause: gopher-lua's compile time is quadratic in a function's distinct
constants (65,536 strings: 7.3 s; lua 19 ms, luajit 13 ms) and LuaJIT refuses more than
65,536 constants per function. Full table in generator.md.

| Model | Model MB | Ops | Before: service.lua | After: service.lua + service/ | types.lua | Generate, luajit (time, max RSS) | Generate, lua |
| --- | ---: | ---: | ---: | --- | ---: | --- | --- |
| infisical/infisical | 34.9 | 2527 | 15.0 MB | 2.2 MB + 121 files, 15.0 MB | 12.2 MB | 6.11 s, 769.8 MB → 6.70 s, 814.6 MB | 8.11 s → 8.90 s |
| cloudflare/zero_trust (sanitized) | 16.6 | 605 | 9.0 MB | 1.8 MB + 73 files, 9.1 MB | 7.8 MB | 3.15 s, 337.9 MB → 3.48 s, 402.6 MB | 4.10 s → 4.47 s |
| stripe/stripe | 16.2 | 648 | 4.7 MB | 0.8 MB + 39 files, 4.7 MB | 7.1 MB | 2.19 s, 287.3 MB → 2.43 s, 314.2 MB | 2.94 s → 3.14 s |
| datadog/v2 | 11.4 | 1760 | 3.8 MB | 0.5 MB + 32 files, 3.9 MB | 4.3 MB | 1.90 s, 229.2 MB → 2.02 s, 267.5 MB | 2.39 s → 2.62 s |
| azure/network (sanitized) | 7.7 | 830 | 2.5 MB | 0.3 MB + 21 files, 2.5 MB | 2.9 MB | 1.02 s, 142.0 MB → 1.11 s, 168.6 MB | 1.39 s → 1.53 s |
| elasticsearch/elasticsearch | 7.5 | 819 | 2.2 MB | 0.3 MB + 19 files, 2.3 MB | 3.8 MB | 1.08 s, 146.8 MB → 1.19 s, 179.9 MB | 1.45 s → 1.61 s |
| aws/ec2 (sanitized) | 7.0 | 823 | 1.5 MB | 0.1 MB + 14 files, 1.5 MB | 3.3 MB | 0.76 s, 120.5 MB → 0.83 s, 128.5 MB | 1.01 s → 1.12 s |
| cloudflare/radar (sanitized) | 6.8 | 281 | 2.2 MB | 0.4 MB + 18 files, 2.2 MB | 2.3 MB | 0.88 s, 125.5 MB → 0.96 s, 143.3 MB | 1.16 s → 1.30 s |
| mongodb-atlas/atlas | 6.8 | 488 | 1.5 MB | 0.2 MB + 13 files, 1.5 MB | 2.7 MB | 0.79 s, 112.4 MB → 0.86 s, 113.8 MB | 1.04 s → 1.18 s |
| github/webhooks | 6.3 | 0 | no operations: skipped, as Distilled does | | | | |
| sentry/sentry | 6.3 | 283 | 2.1 MB | 0.3 MB + 17 files, 2.1 MB | 2.5 MB | 0.88 s, 126.3 MB → 1.00 s, 132.8 MB | 1.20 s → 1.34 s |

`require` of the client, before → after (lua/luajit: time, Lua heap; Rex: time, process max RSS):

| Model | lua 5.5 | luajit | Rex (gopher-lua) |
| --- | --- | --- | --- |
| infisical/infisical | 125.2 ms, 30.6 MB → 19.5 ms, 5.2 MB | refused → 14.0 ms, 5.3 MB | 10655.7 ms, 276.9 MB → **74.2 ms**, 65.6 MB |
| cloudflare/zero_trust | 68.7 ms, 15.1 MB → 9.6 ms, 2.9 MB | refused → 6.7 ms, 2.9 MB | 4125.0 ms, 164.9 MB → **23.5 ms**, 52.3 MB |
| stripe/stripe | 38.9 ms, 9.6 MB → 5.5 ms, 1.9 MB | 34.7 ms, 10.8 MB → 4.0 ms, 1.9 MB | 2564.5 ms, 123.5 MB → **20.0 ms**, 52.8 MB |
| datadog/v2 | 35.1 ms, 9.8 MB → 9.3 ms, 2.6 MB | 32.5 ms, 10.9 MB → 7.2 ms, 2.7 MB | 2866.0 ms, 127.3 MB → **50.0 ms**, 57.5 MB |
| azure/network | 21.6 ms, 5.7 MB → 5.5 ms, 1.6 MB | 18.1 ms, 6.3 MB → 3.6 ms, 1.6 MB | 711.2 ms, 95.0 MB → **20.6 ms**, 52.4 MB |
| elasticsearch/elasticsearch | 21.1 ms, 6.1 MB → 4.1 ms, 1.4 MB | 19.7 ms, 6.8 MB → 2.9 ms, 1.4 MB | 1048.8 ms, 97.2 MB → **23.2 ms**, 52.1 MB |
| aws/ec2 | 14.5 ms, 4.8 MB → 4.5 ms, 1.6 MB | 12.2 ms, 5.3 MB → 3.5 ms, 1.6 MB | 687.4 ms, 76.1 MB → **25.7 ms**, 52.2 MB |
| cloudflare/radar | 17.5 ms, 4.8 MB → 2.5 ms, 1.1 MB | 15.1 ms, 5.3 MB → 2.0 ms, 1.1 MB | 482.1 ms, 88.1 MB → **8.0 ms**, 47.2 MB |
| mongodb-atlas/atlas | 13.6 ms, 3.7 MB → 3.0 ms, 1.1 MB | 11.5 ms, 4.0 MB → 2.6 ms, 1.1 MB | 465.3 ms, 76.5 MB → **12.5 ms**, 49.9 MB |
| sentry/sentry | 17.1 ms, 4.6 MB → 2.6 ms, 1.0 MB | 15.0 ms, 5.1 MB → 2.1 ms, 1.0 MB | 391.2 ms, 83.1 MB → **7.9 ms**, 47.6 MB |

After, the first call of the first operation by name (minimal input, scripted 200 response):

| Model | shape files loaded | lua 5.5 (time, heap after) | luajit | Rex (time, process max RSS) |
| --- | --- | --- | --- | --- |
| infisical/infisical | 1/113 | 14.0 ms, 7.7 MB | 11.5 ms, 7.9 MB | 55.8 ms, 83.2 MB RSS |
| cloudflare/zero_trust | 1/71 | 10.6 ms, 4.5 MB | 9.2 ms, 4.5 MB | 42.7 ms, 65.0 MB RSS |
| stripe/stripe | 5/37 | 11.8 ms, 4.0 MB | 9.7 ms, 4.2 MB | 62.2 ms, 66.1 MB RSS |
| datadog/v2 | 1/27 | 4.7 ms, 3.4 MB | 3.9 ms, 3.7 MB | 20.4 ms, 66.5 MB RSS |
| azure/network | 1/18 | 3.2 ms, 2.2 MB | 2.5 ms, 2.2 MB | 13.3 ms, 57.6 MB RSS |
| elasticsearch/elasticsearch | 1/17 | 3.0 ms, 2.1 MB | 2.3 ms, 2.1 MB | 13.7 ms, 57.1 MB RSS |
| aws/ec2 | 1/11 | 2.5 ms, 2.2 MB | 1.9 ms, 2.2 MB | 11.4 ms, 56.0 MB RSS |
| cloudflare/radar | 1/17 | 3.5 ms, 1.7 MB | 2.9 ms, 1.8 MB | 15.7 ms, 56.4 MB RSS |
| mongodb-atlas/atlas | 1/11 | 2.4 ms, 1.6 MB | 1.9 ms, 1.6 MB | 11.0 ms, 53.9 MB RSS |
| sentry/sentry | 1/16 | 3.0 ms, 1.6 MB | 2.5 ms, 1.7 MB | 15.1 ms, 54.5 MB RSS |

Target met: `require` of the largest client (infisical, 2,527 ops, 36k shapes) takes
74 ms in Rex (was 10.6 s), luajit loads it (refused before), and the first call loads
1 of 113 shape files (56 ms in Rex).

## Commands run (final state, after `git merge main` at 064c7c0)

```text
$ verify/dl doctor
doctor: ok
$ verify/dl test
  lua: ok 1414 passed, 4 pending [Lua 5.5]
  luajit: ok 1414 passed, 4 pending [luajit]
  rex: ok 1401 passed, 9 pending [rex]
$ verify/dl test gen_big
  lua: ok 15 passed / luajit: ok 15 passed / rex: ok 14 passed, 1 pending (CLI case needs io.popen)
$ verify/dl gen-diff neon
ok   diff: clients/neon matches a fresh generation ... gen-diff neon: ok
$ verify/dl conform neon --replay
conform: ok (lua, luajit, rex; 0 mismatches)
$ sh verify/lib/big_models.sh infisical/infisical cloudflare/zero_trust stripe/stripe datadog/v2 \
    azure/network elasticsearch/elasticsearch aws/ec2 cloudflare/radar mongodb-atlas/atlas \
    github/webhooks sentry/sentry          (3 min; tables above)
$ DL_BIG_OUT=/tmp/dl-big-syn sh verify/lib/big_models.sh syn:300:8 syn:1000:8 syn:3000:8 syn:10000:8
  Rex require 1,000 ops 312 -> 33 ms; 3,000 ops 2.3 s -> 97 ms; 10,000 ops 28.3 s -> 333 ms
$ lua|luajit verify/lib/lua_limits.lua ; rex do verify/lib/lua_limits.lua
$ lua|luajit|rex verify/lib/gen_check.lua on the split infisical and stripe outputs
ok gen-check rex: 36175 shapes, 36171 refs resolved, 2527/2527 ops built ...
ok gen-check rex: 14287 shapes, 15653 refs resolved, 648/648 ops built ...
  (lua and luajit too; split output identical from lua and luajit; stylua --check clean)
```

## Skipped / not verified

- `verify/dl gen-diff hetzner` **fails on main too**: `clients/hetzner/*/init.lua` is stale
  after task 13 changed the error-envelope emission (30 init.lua files differ, nothing
  else). Main's generator and this branch's produce byte-identical Hetzner output (checked
  with `git archive main`), so this is not from task 18; task 26 regenerates clients.
- Rex memory is the `rex do` process's maximum RSS (gopher-lua has no
  `collectgarbage("count")`); an empty client run is ~47-54 MB of it.
- Four of the ten models (cloudflare/zero_trust, azure/network, aws/ec2, cloudflare/radar)
  do not generate yet for other tasks' reasons; they were measured after
  `bench_sanitize.mjs` (pagination traits, Azure `apiVersion`, AWS routes/errors patched,
  no operation dropped). github/webhooks has no operations. GCP is not synced (task 21).
- `types.lua` is not split (12 MB for infisical); lua-language-server is not installed,
  so its handling of such a file is untested.

## Open problems

- Op descriptors stay eager: ~33 ms of Rex `require` per 1,000 operations (fine up to
  tens of thousands; infisical, the largest, has 2,527).
- A single enormous shape (tens of thousands of enum values) cannot be split; gopher-lua
  compiles a 100,000-string constructor in 17 s.
- The shape index is ~14% of a split service's size (2.2 MB for infisical, long names).
- `docs/interfaces.md` should record `service.shape_chunks` and the lazy registry
  (STATUS 18); `verify/dl` could wrap `big_models.sh` and `lua_limits.lua`.
