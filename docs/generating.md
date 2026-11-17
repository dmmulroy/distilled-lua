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
(`providers/neon.lua`). Unknown keys are errors. `docs/providers-survey.md` says which
Distilled package needs which key; `providers/*.lua` has one spec per package.

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
| `error_envelope = { code = "/code", message = { "/message", "/error" }, non_empty = true }` | JSON pointers (or lists of them, first text or number wins; `non_empty` skips `""`) to the error code and message (default: top-level `code`, and `message` or `error`) |
| `error_fields_at = "/error"` | where declared error classes' fields live in the body |
| `status_map = { [418] = "Teapot" }` | status -> error tag (a built-in, model or `error_classes` tag), over the built-in status map |
| `error_classes = { Gone = { categories = { "NotFoundError" }, retryable = false } }` | error classes the shared map has no class for (402 PaymentRequired, 410 Gone, ...); a tag a model error or built-in already has is an error |
| `unknown_fields = { reason = "/reason" }` | members of the unknown error read from the body |
| `transform_response = { "strip_nulls", { unwrap = "data", skip_paginated = true } }` | answers with null members dropped (any depth) or an envelope member unwrapped |
| `empty_json_body = true` | send `{}` for a bodied operation without body members |
| `query_style = "brackets"` | nested query values as `a[b]=v` (Stripe) |
| `classify_error = "mod.name"` | a module returning `fn(info) -> err | nil`, consulted before the status map |
| `protocol = "mod.name"` | escape hatch: a module returning `fn(service, spec) -> protocol` for an API that is not plain REST/JSON |
| `naming.words`, `naming.operations` | extra mixed-case words for snake-casing; per-operation method names |
| `models = { skip = { "trust" } }` | multi-model packages: models not generated (Lua model names). A name that is not a model of the package is an error |
| `models = { override = { search = { base_url = ..., title = ... } } }` | per-model changes: `title` (the class name) and `base_url` (a URL string replaces only the default, keeping the option and environment variable; a partial `{ default, option, env }` replaces those fields) |
| `allow_unsupported = { ... }` | emit operations using a feature the runtime does not support yet (they fail with `SdkError` when called) instead of failing generation. No feature needs it today: multipart is supported since task 08, and listing `"multipart"` is an error |

### Options, headers, templated base URLs, OAuth (task 13)

A spec that uses any key of this section is compiled into data for
`rest.new{ provider = ... }` (`lua/distilled/gen/provider_ext.lua` validates it,
`lua/distilled/protocol/rest.lua` interprets it at call time). Classic specs generate
exactly as before.

```lua
return {
  name = "datadog",
  title = "Datadog",
  base_url = {
    default = "https://api.{site}",   -- a template: {option}; no default = required
    option = "base_url",
    env = { "DD_API_BASE_URL" },      -- a name or a list (first set, non-empty wins)
    trim_slash = true,                -- drop trailing slashes
    ensure_suffix = "/api",           -- append unless present (Grafana, Forgejo /api/v1)
    origin = { label = "NetBird API base URL", example = "https://api.netbird.io",
               bare_host = false },   -- only an origin; https unless http on loopback
  },
  auth = { kind = "header", header = "DD-API-KEY", from = "api_key",
           env = { "DD_API_KEY" }, prefix = nil, optional = false },
  --   kind "basic": username = <option>, password = <secret option>
  --   prefix: "token ", "ApiKey ", "Token " (kind "header"); optional: no secret, no header
  options = {
    site = { env = "DD_SITE", default = "datadoghq.com", doc = "Datadog site" },
    application_key = { secret = true, env = "DD_APP_KEY" },
    environment = { env = "COINFLOW_ENV", default = "sandbox",
                    choices = { sandbox = "https://...", production = "https://..." },
                    -- or a list { "Bot", "Bearer" }; ignore_case; invalid = "default"
                  },
    domain = { env = "AUTH0_DOMAIN", strip_scheme = true, trim_slash = true },
  },
  headers = {
    ["DD-APPLICATION-KEY"] = "{application_key}",      -- left out while unset
    Authorization = { "Bearer {access_token}", "{token_id}:{token}" },  -- first that renders
    ["X-Basic"] = { basic = "{email}/token:{api_token}" },              -- Basic base64(...)
  },
  require_one_of = { "access_token", "token" },        -- at least one is set
  public_operations = { "AuthOidc" },                  -- no secret headers, no required checks
  user_agent = { default = "distilled.cloud-github", env = "GITHUB_USER_AGENT" },
  oauth = {                                            -- OAuth 2.0 client credentials
    token_url = "{base_url}/oauth/token",              -- {base_url} is the resolved base URL
    client_id = "client_id", client_secret = "client_secret",  -- options
    into = "access_token",                             -- the option the token fills
    auth = "basic",                                    -- or "form" (fields in the body)
    scope = "scope", extra = { tailnet = "token_tailnet" },
    default_ttl_s = 3600, refresh_window_s = 60,
    reuse = "window",                                  -- or "half": max(ttl - window, ttl / 2)
    required = true,                                   -- a token or client credentials
    exclusive = true,                                  -- both at once is a ConfigError
  },
  glue = "glue/datadog.lua",                           -- see below
}
```

Rules, all checked when the spec loads:

- Every `{name}` in a template is a declared option (auth's `from`, the base URL option and
  `options` declare them). A secret may be in a header, never in the base URL.
- A secret option has no default and no choices (a choice error quotes the value).
- `options` may not reuse a common client option (`retry`, `user_agent`, ...): the
  provider's User-Agent is the `user_agent` key, and the caller's `user_agent` wins.
- A header is declared once (auth's header counts); `User-Agent` is not a header key.
- At call time, a missing required option, an unknown choice and a bad origin are
  `ConfigError`s naming the option and its environment variables, before any request.
  A failed token exchange quotes only the OAuth `error` / `error_description` fields.

### Glue modules

`glue = "glue/<name>.lua"` (relative to the spec) is hand-written Lua for what data cannot
say. The generator loads it to check it (only the functions below are allowed), and copies
it next to the client as `glue.lua` (`require(MODULE .. ".glue")`). It returns a table of:

| Function | Called |
| --- | --- |
| `settings(settings, host, route) -> settings \| nil, err` | after options and OAuth: derive values (Mailchimp's data centre, Rivet's endpoint userinfo) |
| `base_url(settings, route) -> url \| nil, err` | instead of the spec's base URL: per-route hosts (`route = { uri, method, server }`) |
| `headers(settings, route, headers) -> headers` | after the spec's headers |
| `transform_input(input, op) -> input` | before the request is built (Proxmox booleans) |
| `error_envelope(body) -> { code, message }` | instead of `error_envelope` |
| `classify_error(info) -> err \| nil` | first for a failure (`info`: status, code, message, body, headers, now) |
| `classify_success(info) -> err \| true \| nil` | for a 2xx answer: an error, or `true` to read it as a failure (ZeroSSL `success: 0`) |
| `transform_response(body, op) -> body` | instead of `transform_response` |
| `unknown_error(info) -> err` | the error nothing else matched |

A glue function and the spec key of the same name are an error. Glue is plain library
code: it follows the hard rules in `AGENTS.md` (no plain `pcall`, `compat.concat`, no
recursion over data, no secrets in messages). Error classes it defines are module-level
(long-lived), never per call.

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
