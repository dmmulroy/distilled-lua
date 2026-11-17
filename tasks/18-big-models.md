# Task 18: very large models (LuaJIT constant limit, load time, output size)

Read `tasks/10-parity-overview.md` and `STATUS.md` (sections 10-15) first.

`infisical/infisical` generates a `service.lua` that LuaJIT refuses to load (more than
65,536 constants in one function). AWS (434 models, ~19,600 operations), Azure (223),
GCP (529 incl. unstable), Cloudflare (130) and Tencent (263) are next, with models up to
tens of MB. Make the generator's output scale.

## Files you own

```text
lua/distilled/gen/writer.lua, gen/emit.lua, gen/init.lua (emission only), gen/shapes.lua (emission only)
lua/distilled/client.lua      ONLY lazy loading of service data, if you choose that design
verify/lib/gen_check.lua      ONLY what the new layout needs
spec/gen_*_spec.lua (new cases)
verify/features/generator.md  a "large models" section
STATUS.md (section "18 big-models")
```

## Requirements

1. Find every limit that applies on lua 5.1-5.5, LuaJIT and gopher-lua (constants per
   function, upvalues, locals (200), table constructor size, string size, file size,
   gopher-lua's parser/compiler speed and memory) and measure where each bites, with
   synthetic models.
2. Change emission so any model loads on all three runtimes: e.g. split `service.lua`
   into chunks (shapes in several functions or files, ops in several files), and/or load
   operations and shapes lazily on first use (keep `service.ops[name]` semantics or
   change them with a contract update in STATUS). Small models (Neon) should stay
   byte-identical if possible; if not, regenerate `clients/neon` and `clients/hetzner`,
   keep `dl conform neon --replay` green and say why.
3. Report, for the 10 largest models in `models/` (run `verify/dl models sync` first):
   output size, generation time, load time and memory per runtime, before and after.
   Target: `require` of the largest client under 1 s in Rex, a single operation call
   paying only for what it touches if you go lazy.
4. Make `--ops` and the multi-model index still work; keep output deterministic.
