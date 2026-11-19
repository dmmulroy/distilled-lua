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

## Install

### With LuaRocks

The runtime is the rock `distilled`, and each provider's client is its own rock,
`distilled-<provider>` (underscores become dashes: `distilled-boat-dev`). A client rock
depends on the runtime of the same version:

```sh
luarocks install distilled-twitch            # also installs distilled
```

Installed clients are modules under `distilled.clients`, so names such as `aws` or
`twitch` stay free for other rocks:

```lua
local Twitch = require("distilled.clients.twitch")
local R2 = require("distilled.clients.cloudflare.r2")
```

The examples in each client's `README.md` use the vendored name (`require("twitch.chat")`);
with LuaRocks add the `distilled.clients.` prefix. The files are the same: a generated
client finds its own modules from the name it was loaded as.

For Rex (Lua 5.1), install into a tree of its own and put the tree on `package.path`:

```sh
luarocks --lua-version 5.1 --tree ~/.local/share/rex/rocks install distilled-twitch
```

#### Building the rocks

`scripts/build_rocks.sh <version> [rock,...]` writes `dist/rocks/<version>/`: a rockspec,
a source archive and a `.src.rock` per rock, and a manifest. Each rock's source is its
own archive (the rockspec points at a GitHub release asset of tag `v<version>`) because
`clients/` is hundreds of megabytes and a rock built from the git repository would clone
all of it. The directory is a LuaRocks server by itself, so a build can be tried before
it is published:

```sh
scripts/build_rocks.sh 0.1.0 distilled,twitch
luarocks --lua-version 5.1 --tree /tmp/rocks \
  --only-server "file://$PWD/dist/rocks/0.1.0" install distilled-twitch
```

The script's header has the publishing commands (`gh release create`, `luarocks upload`).

### Vendored

Copy the runtime and a client into a `vendor` directory. This copies the R2 service of
the Cloudflare client:

```sh
lua bin/distilled-lua vendor --out vendor
mkdir -p vendor/cloudflare
cp -R clients/cloudflare/r2 vendor/cloudflare/
```

The `vendor` command copies `lua/distilled/` without the generator and the test helpers.
Copy `clients/cloudflare` whole to get all 130 Cloudflare services. Add the directory to
`package.path`:

```lua
package.path = "vendor/?.lua;vendor/?/init.lua;" .. package.path
```

Each client has a `README.md` in `clients/<provider>/`. It lists the client's options,
the environment variables it reads for credentials and every operation.

## Example

Get an R2 bucket, and create it when it does not exist:

```lua
local R2 = require("cloudflare.r2")

local account_id = os.getenv("CLOUDFLARE_ACCOUNT_ID")

-- api_token falls back to CLOUDFLARE_API_TOKEN
local r2 = R2.new({ host = require("distilled.host.popen")() })

local bucket, err = r2:get_bucket({ account_id = account_id, bucket_name = "uploads" })
-- NoSuchBucket is one of get_bucket's declared errors
if err and err.tag == "NoSuchBucket" then
  bucket, err = r2:create_bucket({ account_id = account_id, name = "uploads" })
end
if err then
  error(tostring(err), 0)
end
print(bucket.name, bucket.location)
```

`distilled.host.popen` sends requests with `curl`. In Rex, `distilled.host.rex` sends
them through `rex.exec`. `examples/` has more programs that run against a local fixture
server, so they need no key and no network.

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
requests and the results. The Neon run has 2,095 cases and 0 mismatches. The Cloudflare
comparison in `verify/conform/cloudflare/` has 3,090 cases and 0 mismatches.
`docs/usage.md`, `verify/features/conformance.md` and `verify/features/cloudflare.md` list
the intended differences.

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
| `bin/distilled-lua` | The command line: `package`, `generate`, `vendor` and `rockspec` |
| `scripts/build_rocks.sh` | Builds the LuaRocks release into `dist/rocks/<version>/` |
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
