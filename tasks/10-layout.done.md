# Task 10 (layout): done

Models sync, multi-model packages, `gen-all`, multi-model `gen-diff`, the parity report,
and Hetzner (30 models) as the committed multi-model package. Workflow: `docs/generating.md`.

## What was built

- **`verify/dl models sync [--convert] [pkg ...]`**: mirrors
  `../distilled/packages/<pkg>/.generated-specs/*.json` into `models/<pkg>/<model>.json`
  (all packages when none is named; new / changed / removed counts; `--convert` re-runs
  `scripts/convert.ts` with `node --conditions=bun --experimental-transform-types` first,
  log in `verify/tmp/convert-<pkg>.log`). GraphQL packages are reported as skipped.
  `DL_DISTILLED` overrides the checkout.
- **Models are git-ignored** (`.gitignore`: `/models/*` except `models/neon/neon.json`).
  Decision: **moved** `models/neon.json` to `models/neon/neon.json` (same layout as every
  other package, so `models sync neon` updates it in place and `git diff` shows it) and
  updated every reference (spec/json_spec, spec/gen_neon_spec, spec/gen_output_spec, docs,
  README, NOTICE, examples, `dl json-bench`, the fixtures comment, verify/features/generator.md).
  Generated headers name only the file's basename, so `clients/neon/` is unchanged.
- **Multi-model packages** (`lua/distilled/gen/init.lua`, `gen/provider.lua`):
  - `gen.lua_package_name` (`fly-io` -> `fly_io`), `gen.lua_model_name` (Distilled's slug
    rule: `dnsClient` -> `dns_client`, `combos-rfq` -> `combos_rfq`, digits stay in their
    word: `v1alpha1`, `k8s_v1`, `s3files`). Checked over all 2,123 synced model names: all
    usable and unique per package.
  - `gen.package_layout(pkg, stems)`: one model -> `clients/<lua>/`, module `<lua>`;
    several -> `clients/<lua>/<model>/`, module `<lua>.<model>`. Two stems with one Lua
    name, or a model named `new`/`services` (the index's own fields), fail early.
  - `gen.generate{ ..., model_name = "servers" }`: module `hetzner.servers`, class
    `HetznerServers`, type prefix `hetzner.servers.`, service name, README all follow
    (through `provider.for_model`, which sets `name`, `title`, `package`, `model_name` and
    the model's override).
  - `gen.index{ provider, services }`: the package index `clients/<lua>/init.lua` and a
    README.md with the service table. At run time: `index.services` (sorted),
    `index.<name>` (lazy `require("<lua>.<name>")`), `index.new(options)` (one client per
    service, built on first use with the shared options). Unknown names are nil.
  - Provider spec `models = { skip = {...}, override = { [model] = { title, base_url } } }`,
    strictly validated (unknown keys, bad names, duplicates, skip+override, a bad URL,
    base_url.option = auth.from); `provider.check_models` fails when skip/override name a
    model the package does not have (with the nearest names).
- **`bin/distilled-lua package --models <dir> --provider <file> --out <dir> [--only a,b]`**:
  every model of a package, one `ok`/`skip`/`FAIL` line per model (models without
  operations are skipped, as Distilled does), exit 1 when a model failed (the others are
  still written), a generator raise fails only that model. Writes `<out>.staging` and
  swaps it in (refuses to replace a directory that is not a generated package).
  `generate --model-name <m>` for one model.
- **`verify/dl gen-all [pkg ...] [--jobs N]`**: every package with `models/<pkg>/` and
  `providers/<lua>.lua`, in parallel (`xargs -P`, CPU count, luajit or `DL_GEN_RUNTIME`),
  per-model report and totals.
- **`verify/dl gen-diff <pkg>`**: runs `package` under lua and luajit, diffs them and the
  committed tree, stylua-checks, then `verify/lib/gen_check.lua` in lua, luajit and Rex.
  For a multi-model package gen_check checks the index (requiring it loads no service,
  sorted unique names, `index.<name>` is the module, `index.new` builds lazily and once,
  unknown names nil) and every service as before.
- **`verify/dl parity`** (`verify/lib/parity.lua`): the table below, and
  `verify/features/parity.md` (committed).
- **Hetzner**: `providers/hetzner.lua` (from `packages/hetzner/src/{protocol,credentials,errors}.ts`:
  bearer `token` from `HCLOUD_TOKEN`, base URL `https://api.hetzner.cloud/v1` /
  `HCLOUD_ENDPOINT`, envelope `/error/code` + `/error/message`, `UnknownHetznerError`,
  `HetznerParseError`, wire names) and `clients/hetzner/` (30 models, 178 operations = TS).
- **Spec** `spec/gen_layout_spec.lua` (34 cases; manifest regenerated): provider `models`
  validation and errors, for_model, check_models, names and layout (including collisions),
  one model as a module (and its override base URL in an actual request), refusals, the
  index (lazy loads counted through `package.preload`, `new`, keywords, determinism,
  errors), the `package` CLI (ok / FAIL / skip lines, exit codes, stale skip name,
  wholesale replace, refusal, `--only`, single-model flat layout, `--model-name`), and the
  committed Hetzner client over the scripted transport: request URL and bearer header,
  error envelope (404 -> NotFound with Hetzner's code), unmapped 405 -> UnknownHetznerError,
  a model matcher (403 "server limit" -> ServerLimitExceeded), a 429 retried then ok, page
  pagination over two pages and an empty page, missing token -> ConfigError, HCLOUD_ENDPOINT,
  `hetzner.new` sharing options across services, no token in an error.

## Commands run (final state)

```text
$ verify/dl doctor
ok   lua: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio
ok   luajit: LuaJIT 2.1.1794386141 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
ok   rex: "Lua 5.1"
ok   curl: curl 8.7.1 (x86_64-apple-darwin26.0) libcurl/8.7.1 (SecureTransport) LibreSSL/3.3.6 zlib/1.2.12 nghttp2/1.69.0
ok   stylua: stylua 2.6.0
ok   node: v24.22.1
ok   manifest: spec/manifest.lua lists every spec
doctor: ok
```

```text
$ verify/dl test
== summary
  lua: ok 1082 passed, 4 pending [Lua 5.5]
  luajit: ok 1082 passed, 4 pending [luajit]
  rex: ok 1070 passed, 8 pending [rex]
$ verify/dl test --http --runtime lua
  lua: ok 1125 passed [Lua 5.5]
$ verify/dl fmt --check && echo clean
clean
$ verify/dl conform neon --replay   (last runtime shown; lua and luajit identical)
  members    178 cases:  178 match (0 with intended differences), 0 mismatch, 0 skipped
  requests   904 cases:  904 match (1 with intended differences), 0 mismatch, 0 skipped
  responses  977 cases:  977 match (67 with intended differences), 0 mismatch, 0 skipped
  flows       36 cases:   36 match (11 with intended differences), 0 mismatch, 0 skipped
conform: ok
```

```text
$ verify/dl gen-diff neon
ok   generate: package neon: 1 ok, 0 failed, 0 skipped; 178 operations -> neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 2.1 ms; client loads
ok gen-check luajit: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 2.0 ms; client loads
ok gen-check rex: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 22.7 ms; client loads
gen-diff neon: ok
$ verify/dl gen-diff hetzner
ok   generate: package hetzner: 30 ok, 0 failed, 0 skipped; 178 operations -> hetzner
ok   generate: lua and luajit write identical files
ok   diff: clients/hetzner matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 30 services, 2134 shapes, 2161 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 7.5 ms; client loads
ok gen-check luajit: 30 services, 2134 shapes, 2161 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 7.2 ms; client loads
ok gen-check rex: 30 services, 2134 shapes, 2161 refs resolved, 178/178 ops built, 0 acknowledged unsupported; service load 27.8 ms; client loads
gen-diff hetzner: ok
$ verify/dl gen-all   (the 30 hetzner "ok" lines elided)
package hetzner: 30 ok, 0 failed, 0 skipped; 178 operations -> /Users/dillon/Code/personal/distilled-home/distilled-lua-10/clients/hetzner
ok   neon/neon: 178 operations, 649 shapes
package neon: 1 ok, 0 failed, 0 skipped; 178 operations -> /Users/dillon/Code/personal/distilled-home/distilled-lua-10/clients/neon
gen-all: 2 packages; models: 31 ok, 0 failed, 0 skipped
```

## npm (11 models): proved, not committed

npm's token is optional in Distilled (public operations need none), which a provider
spec cannot say yet (task 13), so its spec is a temporary file and `clients/npm/` is not
committed. The spec also exercises `models.skip` (trust) and `models.override` (search:
base URL and title).

```text
$ for rt in lua luajit; do $rt bin/distilled-lua package --models models/npm \
    --provider /tmp/t10/npm-proof/prov/npm.lua --out /tmp/t10/npm-proof/$rt/npm; done
ok   npm/access: 7 operations, 17 shapes
ok   npm/audit: 1 operations, 11 shapes
ok   npm/oidc: 1 operations, 5 shapes
ok   npm/org: 3 operations, 9 shapes
ok   npm/package_version_status: 1 operations, 4 shapes
ok   npm/publish: 1 operations, 12 shapes
ok   npm/search: 1 operations, 14 shapes
ok   npm/stage: 6 operations, 26 shapes
ok   npm/team: 6 operations, 13 shapes
ok   npm/token: 3 operations, 33 shapes
skip npm/trust: models.skip in the provider spec
package npm: 10 ok, 0 failed, 1 skipped; 30 operations -> /tmp/t10/npm-proof/lua/npm
$ diff -r /tmp/t10/npm-proof/lua /tmp/t10/npm-proof/luajit && echo identical
identical
$ stylua --check --config-path stylua.toml /tmp/t10/npm-proof/lua && echo formatted
formatted
$ lua|luajit verify/lib/gen_check.lua $PWD /tmp/t10/npm-proof/lua npm; rex do ... provider=npm
ok gen-check Lua 5.5: 10 services, 144 shapes, 133 refs resolved, 30/30 ops built, 0 acknowledged unsupported; service load 0.9 ms; client loads
ok gen-check luajit: 10 services, 144 shapes, 133 refs resolved, 30/30 ops built, 0 acknowledged unsupported; service load 1.0 ms; client loads
ok gen-check rex: 10 services, 144 shapes, 133 refs resolved, 30/30 ops built, 0 acknowledged unsupported; service load 2.7 ms; client loads
$ grep -h "base_url = {" /tmp/t10/npm-proof/lua/npm/{search,access}/init.lua
    base_url = { default = "https://search.example.test", env = "NPM_API_BASE_URL" },
    base_url = { default = "https://registry.npmjs.org", env = "NPM_API_BASE_URL" },
```

## Every synced package with a dummy spec (stress test of `package`, not committed)

All models synced (`verify/dl models sync`: 2,123 models, 640 MB), then `package` per
package with the smoke test's dummy spec (bearer, wire names), 10 in parallel with
luajit, aws/gcp/azure/cloudflare left out: 13 s wall time. **939 models ok** (the
smoke test's 939), 524 FAIL (the known failure classes plus tencentcloud's 263),
2 skipped (github/webhooks, resend/webhook_events: no operations). stripe/stripe made
the generator raise (`gen/ops.lua:101`, known from the smoke run); before the
`compat.pcall` in `package` that killed the whole package run, now it is one FAIL line.

## `verify/dl parity`

```text
package            TS ops  Lua ops     models  missing  spec
acme                   12        0        0/1       12  -
adyen                  30        0        0/1       30  -
anthropic             374        0       0/21      374  -
apache-superset       328        0        0/1      328  -
archil                 48        0        0/1       48  -
argocd                106        0        0/1      106  -
auth0                 490        0        0/1      490  -
aws                 19631        0      0/433    19631  -
axiom                  89        0        0/3       89  -
azure               13887        0      0/223    13887  -
boat-dev              118        0        0/1      118  -
boxd                  135        0        0/1      135  -
celld                  22        0        0/2       22  -
chronosphere          149        0        0/1      149  -
clerk                 320        0        0/2      320  -
clickhouse-cloud      181        0       0/16      181  -
cloudflare           3128        0      0/129     3128  -
coinbase              178        0        0/1      178  -
coinflow              207        0       0/18      207  -
convex                 79        0        0/3       79  -
coolify               291        0        0/1      291  -
customerio            161        0        0/1      161  -
datadog              1929        0        0/2     1929  -
daytona               276        0       0/30      276  -
digitalocean          924        0        0/2      924  -
discord               250        0        0/1      250  -
docker                106        0        0/1      106  -
dokploy               639        0       0/59      639  -
doppler               139        0        0/1      139  -
e2b                    97        0       0/16       97  -
elasticsearch         819        0        0/1      819  -
entire                520        0       0/45      520  -
exa                    72        0        0/2       72  -
fly-io                174        0        0/3      174  -
forgejo               496        0       0/10      496  -
gcp                 13901        0        0/0    13901  -
github               1235        0       0/45     1235  -
google-workspace      708        0        0/0      708  -
grafana               250        0        0/1      250  -
growthbook            419        0        0/1      419  -
gusto                 321        0        0/1      321  -
hetzner               178      178      30/30        0  yes
hostinger             421        0        0/1      421  -
huggingface           376        0       0/28      376  -
hydradb                45        0        0/1       45  -
iceberg                34        0        0/1       34  -
infisical            2527        0        0/1     2527  -
inngest                90        0        0/2       90  -
intercom              237        0        0/1      237  -
kubernetes           1160        0       0/23     1160  -
launchdarkly          387        0        0/1      387  -
mailchimp             393        0        0/2      393  -
meilisearch           143        0        0/1      143  -
mercury                89        0        0/1       89  -
metabase              728        0        0/1      728  -
modal                 304        0       0/40      304  -
modrinth               76        0        0/1       76  -
mongodb-atlas         488        0        0/1      488  -
namespacelabs         182        0       0/29      182  -
neon                  178      178        1/1        0  yes
netbird               231        0        0/1      231  -
notion                 62        0       0/15       62  -
npm                    33        0       0/11       33  -
okta                  722        0        0/1      722  -
onepassword            33        0        0/5       33  -
opencode              169        0        0/1      169  -
opensearch            635        0        0/1      635  -
ovh                  4692        0       0/30     4692  -
paypal                115        0       0/13      115  -
plaid                 303        0        0/1      303  -
planetscale           294        0        0/1      294  -
polar                 194        0        0/1      194  -
polymarket            223        0        0/7      223  -
porkbun               177        0        0/1      177  -
posthog              2622        0      0/198     2622  -
prisma                119        0        0/1      119  -
proxmox               684        0       0/49      684  -
questrade              25        0        0/1       25  -
redis-cloud           174        0        0/1      174  -
remote                303        0        0/1      303  -
render                247        0        0/1      247  -
resend                138        0        0/1      138  -
revenuecat            141        0        0/1      141  -
rivet                  19        0        0/6       19  -
s2                     24        0        0/6       24  -
s3                    112        0        0/0      112  -
scaleway             1580        0       0/98     1580  -
sentry                283        0        0/1      283  -
slack                 355        0       0/36      355  -
spacetimedb            18        0        0/1       18  -
squarespace            53        0        0/1       53  -
stackit              1038        0       0/52     1038  -
starburst-galaxy      205        0       0/25      205  -
steel                  54        0       0/10       54  -
stripe                648        0        0/1      648  -
supabase              169        0        0/1      169  -
surrealdb              16        0        0/1       16  -
tailscale              93        0        0/1       93  -
technitium            127        0       0/13      127  -
temporal              104        0        0/1      104  -
tencentcloud        15381        0      0/263    15381  -
trigger-dev            85        0        0/1       85  -
turbopuffer            16        0        0/1       16  -
turso                  53        0        0/1       53  -
typesense              79        0        0/1       79  -
unkey                 113        0        0/1      113  -
vanta                 400        0        0/4      400  -
vercel                476        0       0/42      476  -
whop                  451        0       0/85      451  -
workos                269        0        0/1      269  -
xata                   80        0        0/1       80  -
zendesk               672        0        0/1      672  -
zerossl                11        0        0/1       11  -
total              106595      356    31/2249   106239  2
parity: 356 of 106595 TS operations (0.3%) in 113 packages; 2 packages complete, 2 provider specs
wrote verify/features/parity.md
```

The temporary npm spec (`/tmp/t10/npm-proof/prov/npm.lua`):

```lua
-- Temporary npm spec for the task 10 proof (not committed: npm's token is optional, which
-- a provider spec cannot say yet, task 13).
return {
  name = "npm",
  title = "Npm",
  base_url = { default = "https://registry.npmjs.org", option = "base_url", env = "NPM_API_BASE_URL" },
  auth = { kind = "bearer", from = "token", env = "NPM_TOKEN" },
  unknown_tag = "UnknownNpmError",
  parse_tag = "NpmParseError",
  naming = { members = "wire" },
  models = {
    skip = { "trust" },
    override = { search = { base_url = "https://search.example.test", title = "NpmSearch" } },
  },
}
```

## Skipped, and why

- `verify/dl conform hetzner`: `verify/conform/node/*.mjs` bind only Neon (open since task
  07). Hetzner's request and error behaviour is checked by hand against Distilled's
  sources in `spec/gen_layout_spec.lua` instead (each case names the TS it follows).
- No live Hetzner or npm call (no credentials; the proof bar forbids network in tests).
- `models sync` for gcp: its `.generated-specs/` has `stable/` and `unstable/`
  subdirectories, which the flat `models/<pkg>/<model>.json` layout does not cover; left
  to the GCP task. Cloudflare's `.generated-specs/` (130 models) appeared in the shared
  `../distilled` during this task (another agent's convert); `models sync` picks it up on
  the next run, and `parity` already counts it.
- npm's client is not committed (see above).

## Open problems (also in STATUS.md, section 10)

- `gen/writer.lua` (not mine): a multi-model module's README says "the directory holding
  `hetzner.servers/`" and the headers name the provider spec `hetzner.servers`. Proposed:
  `spec.package or spec.name` (provider.for_model sets `package`). Hetzner's README summary
  is "# Overview" (the first heading of the service doc).
- `gen/ops.lua:101` raises on stripe/stripe (task 11/12).
- Hetzner differs from Distilled until task 13 adds provider-spec support for: extra error
  classes in `status_map` (405 MethodNotAllowed, 410 Gone, 412 PreconditionFailed, today
  `UnknownHetznerError`), the unknown error's `details` field. npm needs an optional token.
- `verify/features/README.md` should list `parity.md`; `verify/SKILL.md` the new commands.
- A per-model `base_url` override given as a string keeps the package's environment
  variable (documented); a model on another host may want its own `env` (table form).
