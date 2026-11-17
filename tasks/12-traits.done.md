# Task 12 (traits): done

Branch `task-12`. Decisions, the hooks task 13 needs, and edits outside my file list are
in `STATUS.md`, section "12 traits".

## What was built

| Requirement | What Distilled does | What distilled-lua does now |
| --- | --- | --- |
| `smithy.api#http` `accept` (mongodb-atlas) | core `HttpTrait.accept`; AtlasProtocol sends it as `Accept` | `op.accept`; `request.build` sets Accept over the protocol's headers (a member bound to Accept wins); REST no longer defaults it to JSON for those ops |
| `server` (digitalocean) | a host name; `baseUrl(creds, { server })` maps it from credentials, unknown server throws | `op.server`; generated client gets option `<server>_base_url` and `rest.route_base_url`; unset is a ConfigError, the request never goes to the main host |
| `baseUrl` (scaleway, stackit) | provider trait extension; Scaleway: the `SCW_API_URL` override applies only to ops on the default host; STACKIT: region rewrite | `op.base_url`; `rest.route_base_url`: equal to the provider default → base_url option, else the op's URL with `{variables}` filled from options of that name (validated as host text). STACKIT's rewrite of non-templated hosts is left to task 13 |
| `rawDownload` (scaleway) | ScalewayProtocol appends `dl=1` | `op.raw_download = true` emitted; nothing appends `dl=1` yet (task 13, STATUS) |
| streaming (`grpc#serverStreaming`, `#clientStreaming`, `openapi#streamWhen`) | generation fails unless the SdkSpec has `streams: true`; streamWhen's plain call keeps the output | `provider.UNSUPPORTED.streaming`; with `allow_unsupported = { "streaming" }`, server/client streaming ops get `unsupported = "streaming"` (SdkError at call time, nothing sent), streamWhen ops are emitted as their plain call. modal (10 models) and boxd generate; not callable until a gRPC protocol exists |
| Exa `ListWebsets` `_items` vs `ListWebsetsItems` | no collision (`.items()` is a sub-method) | real operations keep their names; the colliding sibling becomes `list_websets_all_items` (`op.pagination_methods`, read by `client.lua`, types.lua, README) |
| Resend cursor without `outputToken` | provider strategy `paginateResend` (last item's id); generic: `assertPaginationFields` fails | emitted unpaginated with a CLI warning (only for cursor + `hasNextPage` + missing outputToken; other missing fields still fail) |
| `distilled.errors#bodies` on a prelude target (coinflow, workos, zendesk) | skipped (`!shapes[target]`) | skipped; dangling non-prelude target still fails |
| path label with no member (proxmox `{url_seq}`) | emitted; the placeholder is sent literally | emitted with a warning; `request.build` fills it from the input key of that name (label rules) or fails with InvalidInput |
| found: prelude output (Stripe `smithy.api#Document`) | output schema is the prelude | crashed `ops.output`; now `output = S.unknown`, `output_raw = true` |
| found: Unit output named like an operation (Mailchimp `GetSurveyResponse`) | overwrites the map entry | gave an unresolvable ref (gen-check failed on main); now replaced the same way; a non-empty shape under the name fails generation |

Specs: `spec/gen_traits_spec.lua` (new, 31 cases: generation, generated clients end to end
over `testing.host`, `rest.route_base_url`), `spec/request_spec.lua` (9 new cases), and
updated cases in `gen_naming_spec`, `gen_provider_spec`, `gen_ops_spec`,
`gen_shapes_spec`. `verify/lib/gen_check.lua` accepts acknowledged-unsupported ops and
fills every path placeholder.

## Smoke before / after (requirement 6)

`sh tasks/notes/smoke-run1.sh <pkg>/<model>` over all 1,206 models (`xargs -P 10`), with
`allow_unsupported = { "streaming" }` added to the dummy spec for modal, boxd, boat-dev.

- All models: **939 → 1,089 OK**, 267 → 117 FAIL. No model that generated before fails
  now (`comm -23` of the OK lists is empty). Full list: `tasks/notes/smoke-results-12.txt`.
- My classes (models failing on that class in `tasks/notes/smoke-results.txt` → now OK):

  | Class | Before failing | Now OK |
  | --- | --- | --- |
  | http `baseUrl` (scaleway 98, stackit 52) | 150 | 135 |
  | http `server` (digitalocean) | 1 | 0 |
  | http `accept` (mongodb-atlas) | 1 | 0 |
  | streaming (modal 10, boxd, boat-dev) | 12 | 12 |
  | Exa `_items` collision | 1 | 0 |
  | Resend cursor without outputToken | 1 | 0 |
  | errors#bodies prelude (coinflow 2, workos, zendesk) | 4 | 2 |
  | proxmox label | 1 | 1 |
  | stripe `ops.lua:101` crash | 1 | 0 |

  Every model in that table still failing (22) fails only on a task 11 class (nullable list
  items/map values, a type name). In a scratch copy with those task 11 checks switched off
  all 22 generate (`OK exa/api`, `OK digitalocean/digitalocean`, `OK mongodb-atlas/atlas`,
  `OK resend/resend`, `OK stripe/stripe`, `OK workos/workos`, `OK zendesk/zendesk`, 15
  scaleway/stackit).
- gen-check (`luajit verify/lib/gen_check.lua`) over all 1,089 generated outputs: 1,087 ok,
  2 failed: `mailchimp_marketing` (the named-io bug above, also on main; fixed, re-run ok)
  and `infisical_infisical` (its service.lua exceeds LuaJIT's 65,536 constants; not mine).

## Generated clients end to end (lua, luajit, rex)

`/tmp/t12e2e/run.lua` loads smoke-generated clients with the real runtime and a scripted
host; identical output on `lua`, `luajit` and `rex do`:

```text
digitalocean_digitalocean.list_inference_models: GET https://inference.do-ai.run/v1/models accept=application/json ok
digitalocean_digitalocean.list_inference_models: no request err=ConfigError:inference_base_url
mongodb_atlas_atlas.accept_group_stream_vpc_peering_connection: POST https://example.invalid/api/atlas/v2/groups/g/streams/vpcPeeringConnections/i:accept accept=application/vnd.atlas.2023-02-01+json ok
stackit_observability.create_alert_config_receiver: POST https://argus.api.eu01.stackit.cloud/v1/projects/p/instances/i/alertconfigs/receivers accept=application/json ok
stackit_observability.create_alert_config_receiver: no request err=ConfigError:region
modal_app.app_get_logs: no request err=SdkError:operation AppGetLogs: distilled-lua cannot perform streaming operations yet (...)
exa_api.list_websets_items: GET https://example.invalid/websets/v0/websets/w/items accept=application/json ok
exa_api.list_websets_all_items: 1 nil
```

## Proof bar (commands and output)

```text
$ verify/dl doctor
...
ok   manifest: spec/manifest.lua lists every spec
doctor: ok

$ verify/dl test
== summary
  lua: ok 1090 passed, 4 pending [Lua 5.5]
  luajit: ok 1090 passed, 4 pending [luajit]
  rex: ok 1083 passed, 7 pending [rex]

$ verify/dl test --http --runtime luajit
  luajit: ok 1133 passed [luajit]

$ verify/dl gen-diff neon
ok   generate: lua and luajit write identical files
ok   diff: clients/neon matches a fresh generation
ok   stylua --check: generated Lua is formatted
ok gen-check Lua 5.5: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; ...
ok gen-check luajit: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; ...
ok gen-check rex: 649 shapes, 835 refs resolved, 178/178 ops built, 0 acknowledged unsupported; ...
gen-diff neon: ok

$ verify/dl conform neon --replay
== conform neon [Lua 5.5]   conform: ok
== conform neon [luajit]    conform: ok
== conform neon [rex]       conform: ok
  (members 178, requests 904, responses 977, flows 36; 0 mismatch)

$ stylua --check lua spec verify/lib/gen_check.lua   # clean
```

Pending specs are the existing environment-gated ones (stylua/io.popen under Rex, Node,
DL_SERVE_URL, verify/tmp); none are from this task.

## Skipped, and why

- No live API calls (none allowed). Hosts, Accept and refusals are checked against the
  scripted host only.
- Scaleway `dl=1` for `raw_download` ops, STACKIT's region rewrite of plain hosts and
  default region, DigitalOcean server defaults, Scaleway's default `{region}`/`{zone}`
  labels: provider-spec features (task 13 owns provider keys). The hooks are in place;
  what they need is in STATUS.
- Resend full pagination: needs a runtime strategy (`paginate.lua`) and a provider key;
  the ops are emitted as plain calls.
- The stream variant of streaming ops: no streaming in the runtime; modal/boxd need gRPC.
- `smithy.api#http` `apiVersion` (azure), `smithy.api#streaming` (AWS): later tasks.

## Open problems

- `infisical/infisical`: generated service.lua does not load in LuaJIT (too many
  constants in one function). Emission problem for very large models (task 10 or 06).
- `docs/interfaces.md` needs the new op fields, `rest.route_base_url`, request.build rules
  12-14 (orchestrator; listed in STATUS).
