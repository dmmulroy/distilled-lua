# distilled-lua

Typed API clients for Lua, generated from API models. You get a Lua module per API
(today: [Neon](https://neon.tech)'s 178 operations) that builds requests, retries,
pages through lists, matches errors and keeps secrets out of logs, in pure Lua with no
dependencies. The same files run on PUC Lua 5.1 to 5.5, LuaJIT and gopher-lua inside
[Rex](https://www.superlogical.com/rex/).

## 30 seconds

```lua
local Neon = require("neon")                 -- the generated client (clients/neon)
local neon = Neon.new({ host = require("distilled.host.popen")() })   -- NEON_API_KEY from the env

local res, err = neon:get_project({ project_id = "quiet-sun" })
if err then
  if err.tag == "NotFound" then return nil end          -- errors are values, not exceptions
  error(tostring(err), 0)
end
print(res.project.name)

for project in neon:list_projects_items({ limit = 50 }) do   -- every page, lazily
  print(project.id)
end
```

That is `examples/plain_lua.lua`, which runs against a local fixture server (no key, no
network):

```sh
verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
  NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon lua examples/plain_lua.lua'
```

Calls return `value` or `nil, err`; nothing raises. `err` has a `tag` (`"NotFound"`),
`categories` (`err.categories.AuthError`), `status`, `message` and `retryable`. Transient
failures (429, 5xx, transport errors) are retried with backoff, honouring `Retry-After`,
inside an optional deadline. Fields the model marks sensitive come back wrapped so they
print as `<redacted>`.

## Where it comes from: Distilled

[Distilled](https://github.com/alchemy-run/distilled) is a TypeScript (Effect) SDK
generator. It converts each provider's OpenAPI or Smithy spec into a *patched* Smithy
model: error matchers learned from real responses, pagination traits, sensitive fields,
telemetry names. distilled-lua reuses those models unchanged and has its own runtime and
generator, written in Lua:

```text
provider spec ─ Distilled convert (Node, once per spec update) ─▶ models/neon.json
models/neon.json + providers/neon.lua ─ bin/distilled-lua generate ─▶ clients/neon/
clients/neon/ + lua/distilled/ ─ require("neon") ─▶ your Lua program
```

Behaviour follows Distilled's runtime closely and is checked against it:
`verify/dl conform neon` feeds the same inputs and canned responses to both and diffs
the requests and outcomes (2,093 cases, 0 mismatches; the few intended differences are
listed in `docs/usage.md` and `verify/features/conformance.md`).

## Documentation

| | |
| --- | --- |
| [docs/usage.md](docs/usage.md) | clients, calls, errors, pagination, retry, secrets, validation, the host seam |
| [docs/rex.md](docs/rex.md) | using a client from a Rex configuration |
| [docs/generating.md](docs/generating.md) | producing a model, provider specs, `--ops`, vendoring, adding a provider |
| [docs/tracing.md](docs/tracing.md) | OpenTelemetry spans, exporters, `dl trace`, Jaeger |
| [docs/interfaces.md](docs/interfaces.md) | module contracts (for contributors) |
| [verify/SKILL.md](verify/SKILL.md) | how to verify a change (`verify/dl`, the proof bar, the feature map) |

## Layout

```text
lua/distilled/      the runtime (copy it next to a client to use it; see docs/generating.md)
lua/distilled/gen/  the generator (not needed at run time)
bin/distilled-lua   generate | vendor
providers/          provider specs (one small Lua table per API)
models/             patched Smithy models produced by Distilled
clients/neon/       the generated Neon client
examples/           runnable examples used by the docs
spec/               tests (run under all three runtimes)
verify/             verification toolkit: verify/dl, conformance, feature map
```

## Status

- REST/JSON APIs with bearer or header auth (Neon). AWS signing, Cloudflare's envelope,
  GraphQL and gRPC are not supported yet.
- Neon: all 178 operations generated; 177 compared request-for-request with Distilled,
  the multipart upload operation is being added (task 08).
- The core is synchronous; streaming responses are not supported.
- Not on LuaRocks: clients are vendored into the consuming project.

```sh
verify/dl doctor     # toolchain check
verify/dl test       # all specs under lua, luajit and rex
verify/dl help       # everything else
```
