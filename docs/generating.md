# Generating a client

```text
provider spec (OpenAPI/Smithy) ─ Distilled convert ─▶ patched Smithy model (JSON)
model + providers/<name>.lua ─ bin/distilled-lua generate ─▶ <out>/{init,service,types}.lua, README.md
```

The generator is Lua (`lua/distilled/gen/`, run by `bin/distilled-lua` under lua 5.1+ or
LuaJIT); Node is only needed for Distilled's converter.

## 1. Producing a model with Distilled

[Distilled](https://github.com/alchemy-run/distilled) converts each provider's upstream
spec into a Smithy 2.0 JSON model and applies its patches (error matchers observed on
the live API, pagination, sensitive fields, telemetry names). For Neon:

```sh
cd ../distilled
pnpm install --filter "@distilled.cloud/neon..."
pnpm --filter @distilled.cloud/neon run specs:fetch     # the OpenAPI spec mirror (git submodule)
pnpm --filter @distilled.cloud/neon run convert         # -> packages/neon/.generated-specs/neon.json
cp packages/neon/.generated-specs/neon.json ../distilled-lua/models/neon.json
```

`models/neon.json` in this repository is such a model (Distilled's Neon spec at the time
of writing). The generated files name the model's hash in their header, and
`verify/dl gen-diff neon` regenerates and diffs, so a stale client is visible.

## 2. Generating

```sh
lua bin/distilled-lua generate --model models/neon.json --provider providers/neon.lua \
  --out clients/neon [--ops list_projects,get_project] [--no-telemetry] [--quiet]
```

- `--ops` keeps the listed operations (Lua names, comma-separated) and only the shapes
  they reach. An unknown name fails with the nearest names
  (`unknown operation list_projectz; nearest: list_projects, get_project, count_projects`).
- `--no-telemetry` leaves span metadata out (smaller output; spans fall back to the
  operation name).
- Output: `init.lua` (what `require("<name>")` returns: `Client.define` with the
  protocol and options), `service.lua` (shapes, errors and operations as plain data),
  `types.lua` (LuaLS `---@meta` annotations; not loaded at run time) and `README.md`
  (options and every operation). Output is deterministic: same model, spec and generator
  give byte-identical files.
- The generator fails at generation time, never at call time: a dangling shape, two
  operations that collide after snake-casing, a pagination trait naming a missing
  member, a regular expression in an error matcher that does not compile, or a trait it
  does not understand under the `smithy.api#http*`, `com.distilled.*` or `distilled.*`
  namespaces all stop generation with the shape or operation named.

## 3. Vendoring

Clients are copied into the consuming project; there is no package to install.

```sh
lua bin/distilled-lua vendor --out vendor                 # vendor/distilled/... (runtime only)
lua bin/distilled-lua generate ... --out vendor/neon      # the client next to it
```

`vendor` copies `lua/distilled/` without `gen/` (the generator) and `testing/` (test
seams). Put `vendor/?.lua;vendor/?/init.lua` on `package.path` and `require("neon")`.
`examples/vendored_client.lua` checks a vendored tree from a clean directory under each
runtime. A client finds its own `service.lua` by its module name, so it can be vendored
under another name (`vendor/neon_v2`, required as `neon_v2`).

## 4. Provider specs

Everything about a provider that the model does not say, in one declarative table
(`providers/neon.lua`). Unknown keys are errors.

```lua
return {
  name = "neon",                          -- module name and type prefix
  title = "Neon",                         -- human name in docs
  base_url = {                            -- or just a URL string
    default = "https://console.neon.tech/api/v2",
    option = "base_url",                  -- client option that overrides it
    env = "NEON_API_BASE_URL",            -- environment variable that overrides it
  },
  auth = { kind = "bearer", from = "api_key", env = "NEON_API_KEY" },
  --   kind "bearer": authorization: Bearer <secret>; "header": header = "x-api-key"; "none"
  unknown_tag = "UnknownNeonError",       -- error nothing else matched
  parse_tag = "NeonParseError",           -- 2xx body that could not be decoded
  naming = { members = "wire" },          -- keep wire names ("snake_case" to convert)
  pagination = { items_fallback = "items" },
}
```

Optional keys:

| Key | |
| --- | --- |
| `error_envelope = { code = "/code", message = "/message" }` | JSON pointers to the error code and message in an error body (default: top-level `code` and `message`) |
| `error_fields_at = "/error"` | where declared error classes' fields live in the body |
| `status_map = { [418] = "Teapot" }` | status -> error tag, over the built-in status map |
| `classify_error = "mod.name"` | a module returning `fn(info) -> err | nil`, consulted before the status map |
| `protocol = "mod.name"` | escape hatch: a module returning `fn(service, spec) -> protocol` for an API that is not plain REST/JSON |
| `naming.words`, `naming.operations` | extra mixed-case words for snake-casing; per-operation method names |
| `allow_unsupported = { ... }` | emit operations using a feature the runtime does not support yet (they fail with `SdkError` when called) instead of failing generation |

## 5. Adding a provider

1. Get its patched model from Distilled (step 1; Distilled must already support the
   provider) into `models/<name>.json`.
2. Write `providers/<name>.lua`. Start from Distilled's hand-written glue for that
   provider (`packages/<name>/src/protocol.ts`, `credentials.ts`, `errors.ts`): base URL,
   auth header, environment variables, the unknown and parse error names, the error
   envelope.
3. `lua bin/distilled-lua generate --model models/<name>.json --provider providers/<name>.lua --out clients/<name>`.
   Fix what the generator refuses (it names the shape or trait).
4. `verify/dl gen-diff <name>` loads the client under lua, luajit and Rex, resolves every
   reference and builds a request for every operation.
5. To compare with Distilled, `verify/conform/node/*.mjs` needs a binding for the
   provider (they import `@distilled.cloud/<name>` by path); `verify/dl conform <name>`
   then works as for Neon.

Only REST/JSON with bearer or header authentication is supported today (AWS signing,
Cloudflare's response envelope, GraphQL and gRPC are not).
