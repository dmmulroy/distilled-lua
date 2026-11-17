# Generating a client

```text
provider spec (OpenAPI/Smithy) ─ Distilled convert ─▶ ../distilled/packages/<pkg>/.generated-specs/*.json
                               ─ verify/dl models sync ─▶ models/<pkg>/<model>.json
models/<pkg>/ + providers/<lua>.lua ─ bin/distilled-lua package ─▶ clients/<lua>/
```

The generator is Lua (`lua/distilled/gen/`, run by `bin/distilled-lua` under lua 5.1+ or
LuaJIT); Node is only needed for Distilled's converter.

The everyday loop, for every package at once:

```sh
verify/dl models sync            # copy Distilled's models into models/ (git-ignored)
verify/dl gen-all                # regenerate every package with a provider spec, in parallel
verify/dl gen-diff hetzner       # check one package in lua, luajit and Rex
verify/dl parity                 # how many of Distilled's operations we have
```

## 1. Models

[Distilled](https://github.com/alchemy-run/distilled) converts each provider's upstream
spec into Smithy 2.0 JSON models and applies its patches (error matchers observed on
the live API, pagination, sensitive fields, telemetry names). Each package
(`../distilled/packages/<pkg>`) writes one or more models to `.generated-specs/`:
Neon has one, Hetzner 30 (one per API tag), Posthog 198.

`verify/dl models sync [pkg ...]` copies them to `models/<pkg>/<model>.json` (every package
when none is named) and reports what is new, changed or removed; `--convert` first re-runs
the package's `scripts/convert.ts` (`node --conditions=bun --experimental-transform-types`;
the package's spec mirror must be fetched and `pnpm install` done in `../distilled`).
`DL_DISTILLED` points at another checkout. GraphQL packages (linear, railway, expo-eas)
are reported as skipped: they have no Smithy model.

Models are **not committed** (as in Distilled, where `.generated-specs` is ignored), except
`models/neon/neon.json`, which the specs and `verify/dl conform neon` need. A sync that
changes it shows up in `git diff`. Generated clients are committed; their files name the
model's hash in the header, and `verify/dl gen-diff <pkg>` regenerates and diffs, so a
stale client is visible.

To produce one package's models by hand:

```sh
cd ../distilled
pnpm install --filter "@distilled.cloud/neon..."
pnpm --filter @distilled.cloud/neon run specs:fetch     # the OpenAPI spec mirror (git submodule)
pnpm --filter @distilled.cloud/neon run convert         # -> packages/neon/.generated-specs/neon.json
cd - && verify/dl models sync neon
```

## 2. Generating

A whole package (what `gen-all` and `gen-diff` run):

```sh
lua bin/distilled-lua package --models models/hetzner --provider providers/hetzner.lua \
  --out clients/hetzner [--only servers,volumes] [--no-telemetry] [--quiet]
```

It prints one line per model and a summary, and exits 1 when a model failed (the others
are still written):

```text
ok   hetzner/servers: 6 operations, 247 shapes
skip github/webhooks: no operations          (Distilled skips these too)
skip npm/trust: models.skip in the provider spec
FAIL stripe/stripe: generator raised: ...    (the first line of the error)
package hetzner: 30 ok, 0 failed, 0 skipped; 178 operations -> clients/hetzner
```

It writes into `<out>.staging` and then replaces `<out>` wholesale, so a model that is
gone or no longer generates leaves nothing stale; it refuses to replace a directory that
is not a generated package. `--only` (Lua model names) is for debugging: the package is
replaced by just those models.

One model:

```sh
lua bin/distilled-lua generate --model models/neon/neon.json --provider providers/neon.lua \
  --out clients/neon [--ops list_projects,get_project] [--no-telemetry] [--quiet]
lua bin/distilled-lua generate --model models/hetzner/servers.json \
  --provider providers/hetzner.lua --out /tmp/servers --model-name servers   # hetzner.servers
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

### Packages and module names

Module names come from the package name, with `-` replaced by `_` (`fly-io` -> `fly_io`,
`mongodb-atlas` -> `mongodb_atlas`). Model names are the file names with camel boundaries
split and any other separator turned into `_`, lower-cased (`dnsClient` -> `dns_client`,
`combos-rfq` -> `combos_rfq`, `autoscaling_v1alpha2` unchanged), the rule of Distilled's tag
slugs.

- **One model** (Neon, Stripe): `clients/<lua>/`, `require("<lua>")` is the client class.
- **Several models** (Hetzner, npm, Posthog): one client class per model in
  `clients/<lua>/<model>/`, `require("<lua>.<model>")`, with the type prefix
  `<lua>.<model>.` in `types.lua` and the class name `<Title><Model>` (`HetznerServers`).
  `clients/<lua>/init.lua` is the package index, with a README.md listing the services:

```lua
local hetzner = require("hetzner")      -- loads no service yet
hetzner.services                        -- { "actions", "certificate_actions", ... } (sorted)
local Servers = hetzner.servers         -- require("hetzner.servers"), on first use
local client = Servers.new({ token = key, host = require("distilled.host.popen")() })
client:list_servers({})

-- one set of options for every service; each client is built on first use
local clients = hetzner.new({ token = key, host = require("distilled.host.popen")() })
clients.volumes:get_volume({ id = 1 })
clients["end"]                          -- a service named after a Lua keyword
```

  An unknown name is `nil` on both. No model may be called `new` or `services` (the
  generator refuses it), and two files with the same Lua name are an error.

A model without operations is skipped, as Distilled does (`github/webhooks`).

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

A multi-model package is vendored as a whole directory (`cp -R clients/hetzner vendor/`),
or one service of it: `vendor/hetzner/servers/` alone is `require("hetzner.servers")`
without the index. The index finds its services by its own module name too.

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
| `models = { skip = { "trust" } }` | multi-model packages: models not generated (Lua model names). A name that is not a model of the package is an error |
| `models = { override = { search = { base_url = ..., title = ... } } }` | per-model changes: `title` (the class name) and `base_url` (a URL string replaces only the default, keeping the option and environment variable; a partial `{ default, option, env }` replaces those fields) |
| `allow_unsupported = { ... }` | emit operations using a feature the runtime does not support yet (they fail with `SdkError` when called) instead of failing generation. No feature needs it today: multipart is supported since task 08, and listing `"multipart"` is an error |

## 5. Adding a provider

1. `verify/dl models sync <pkg>` (step 1; Distilled must already support the provider).
2. Write `providers/<lua>.lua` (`name` is the Lua package name). Start from Distilled's
   hand-written glue for that provider (`packages/<pkg>/src/protocol.ts`,
   `credentials.ts`, `errors.ts`): base URL, auth header, environment variables, the
   unknown and parse error names, the error envelope. One spec serves every model of the
   package; `models` skips or adjusts single models.
3. `verify/dl gen-all <pkg>` writes `clients/<lua>/`. Fix what the generator refuses (it
   names the model, shape or trait).
4. `verify/dl gen-diff <pkg>` loads the client under lua, luajit and Rex (through the index
   for a multi-model package: lazy loading, every service, `new`), resolves every
   reference and builds a request for every operation.
5. `verify/dl parity` updates `verify/features/parity.md`.
6. To compare with Distilled, `verify/conform/node/*.mjs` needs a binding for the
   provider (they import `@distilled.cloud/<name>` by path); `verify/dl conform <name>`
   then works as for Neon.

Only REST/JSON with bearer or header authentication is supported today (AWS signing,
Cloudflare's response envelope, GraphQL and gRPC are not).
