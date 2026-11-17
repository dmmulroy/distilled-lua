# distilled-lua

Lua API clients for 115 cloud and SaaS providers. The generator builds each client from
the Smithy model that [Distilled](https://github.com/alchemy-run/distilled) produces for
that provider, so each operation has a known input, a known output and a list of the errors it
can return. The runtime and the generator are pure Lua with no dependencies. The same
files run on PUC Lua 5.1 to 5.5, on LuaJIT and on gopher-lua inside
[Rex](https://www.superlogical.com/rex/).

- **Errors are values.** A call returns its result, or `nil` and an error table. The
  table has a `tag` such as `"NotFound"`, a set of categories, the HTTP status and the
  message from the response body. A failed request never raises.
- **Retries.** Throttling and transient failures retry with jittered backoff by default.
  The client waits at least as long as `Retry-After` asks and stops at an optional
  deadline.
- **Pagination as an iterator.** A paginated operation has an `_items` method and a
  `_pages` method. Both fetch the next page only after the loop has read the current one.
- **Redacted secrets.** A field that the model marks sensitive prints as `<redacted>`.
  `distilled.json.encode` refuses to encode it.
- **Streams.** `client:<op>_stream` reads NDJSON, server-sent events, gRPC, Connect and
  AWS event streams one item at a time.

distilled-lua is not on LuaRocks. You copy the runtime and the clients you need into your
project.

## Install

Copy the runtime and a client into a `vendor` directory:

```sh
lua bin/distilled-lua vendor --out vendor
cp -R clients/neon vendor/
```

The `vendor` command copies `lua/distilled/` without the generator and the test helpers.
Add the directory to `package.path`:

```lua
package.path = "vendor/?.lua;vendor/?/init.lua;" .. package.path
```

Each client has a `README.md` in `clients/<provider>/`. It lists the client's options,
the environment variables it reads for credentials and every operation.

## Example

Get a Neon project, return `nil` when it does not exist, and then list every project:

```lua
local Neon = require("neon")

-- api_key falls back to NEON_API_KEY
local neon = Neon.new({ host = require("distilled.host.popen")() })

local res, err = neon:get_project({ project_id = "quiet-sun" })
if err then
  if err.tag == "NotFound" then
    return nil
  end
  error(tostring(err), 0)
end
print(res.project.name)

local it = neon:list_projects_items({ limit = 50 })
for project in it do
  print(project.id)
end
if it.err then
  error(tostring(it.err), 0)
end
```

`distilled.host.popen` sends requests with `curl`. In Rex, `distilled.host.rex` sends
them through `rex.exec`. A longer version of this example is `examples/plain_lua.lua`.
It runs against a local fixture server, so it needs no key and no network:

```sh
verify/dl serve run sh -c 'lua examples/serve_neon_fixture.lua &&
  NEON_API_KEY=fake NEON_API_BASE_URL=$DL_SERVE_URL/neon lua examples/plain_lua.lua'
```

## Providers and protocols

The generated clients cover 105,759 of the 106,595 operations in Distilled's TypeScript
SDKs. `verify/features/parity.md` has the count for each provider.

The runtime implements these protocols:

- REST with JSON, with bearer, header or OAuth credentials
- AWS, with SigV4 signing, the JSON, query and XML protocols, event streams and S3
- Cloudflare's response envelope
- Azure, GCP, Google Workspace and Tencent Cloud
- GraphQL, for Linear, Railway, Expo EAS and GitHub
- gRPC and Connect, for Modal, boxd, Namespace and E2B
- Signed REST requests for Coinbase and Polymarket

## How it relates to Distilled

Distilled converts each provider's OpenAPI or Smithy spec into a Smithy model and then
patches it. The patches add error matchers observed on the live API, pagination traits,
sensitive fields and telemetry names. distilled-lua reads those models without changes.
Its own runtime and generator are Lua.

Building a client takes three steps:

1. Distilled's converter writes the model. This step needs Node and runs once per spec
   update.
2. `bin/distilled-lua` reads the model and a provider spec from `providers/` and writes
   the client to `clients/<provider>/`.
3. Your program loads the client and the runtime with `require`.

The runtime follows Distilled's runtime and is tested against it. `verify/dl conform neon`
sends the same inputs and canned responses through both runtimes and compares the
requests and the results. The Neon run has 2,095 cases and 0 mismatches.
`docs/usage.md` and `verify/features/conformance.md` list the intended differences.

## Documentation

| File | What it covers |
| --- | --- |
| [docs/usage.md](docs/usage.md) | Clients, calls, errors, pagination, retries, secrets, validation and the host adapter |
| [docs/rex.md](docs/rex.md) | Using a client from a Rex configuration |
| [docs/generating.md](docs/generating.md) | Syncing models, provider specs, `--ops`, vendoring and adding a provider |
| [docs/tracing.md](docs/tracing.md) | OpenTelemetry spans, exporters, `dl trace` and Jaeger |
| [docs/interfaces.md](docs/interfaces.md) | The contracts between modules, for contributors |
| [verify/SKILL.md](verify/SKILL.md) | How to verify a change with `verify/dl` |

## Repository layout

| Path | What it holds |
| --- | --- |
| `lua/distilled/` | The runtime: protocols, errors, retries, pagination, credentials, streams, tracing |
| `lua/distilled/gen/` | The generator. A program does not need it at run time |
| `bin/distilled-lua` | The command line: `package`, `generate` and `vendor` |
| `providers/` | One spec per provider. A spec is a Lua table with what the model does not say |
| `models/` | Models synced from Distilled. Git tracks only `models/neon/neon.json` |
| `clients/` | The generated clients, one directory per provider |
| `examples/` | Runnable examples that the docs refer to |
| `spec/` | Tests, run under Lua, LuaJIT and Rex |
| `verify/` | `verify/dl`, the conformance test against Distilled and the feature map |

## Development

```sh
verify/dl doctor     # check the interpreters, curl, Rex, stylua and node
verify/dl test       # run every spec under lua, luajit and rex
verify/dl help       # list the other commands
```

## License

Apache-2.0. See `LICENSE` and `NOTICE`. distilled-lua is derived from
[Distilled](https://github.com/alchemy-run/distilled), which is also Apache-2.0.
