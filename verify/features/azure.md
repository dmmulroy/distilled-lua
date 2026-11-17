# Azure Resource Manager (`clients/azure`, `distilled.protocol.azure`)

## Sub-features

- **223 clients, 13,869 operations**: one module per resource provider
  (`require("azure.compute")`), the index `require("azure")` (`azure.services`,
  `azure.new(options)`). Every operation of Distilled's `@distilled.cloud/azure` for the
  same models exists by name (TS counts 13,887: the extra 18 are `planetarycomputer.ts`
  and `portal.ts`, stale TS files with no model in `.generated-specs`). Method names are
  the ARM operation ids in snake_case (`GetResourceGroup` -> `get_resource_group`);
  member names are the model's (`resourceGroupName`, `_filter` for `$filter`), as TS.
- **Generator support** (`lua/distilled/gen/azure.lua`, applied when the provider spec
  says `protocol = "distilled.protocol.azure"`):
  - `op.api_version` from the http trait's `apiVersion` (else the
    `com.distilled.openapi#apiVersion` trait; the http trait wins when they differ, as
    Distilled's fold does); an api-version under any other protocol fails generation;
  - generate.ts's `markScopeLabelsGreedy`: a label that is the whole leading path
    segment (`/{scope}/providers/...`, `/{resourceId}`) becomes greedy `{scope+}`;
  - ARM ids that differ only in case (workloads: `GetSapVirtualInstance` 2024-09-01 and
    `GetSAPVirtualInstance` 2023-04-01) would both be `get_sap_virtual_instance`: the
    newest api-version keeps the name, the others get it as a suffix
    (`get_sap_virtual_instance_2023_04_01`). `naming.operations` in the spec wins.
- **Protocol** (`lua/distilled/protocol/azure.lua`, port of `protocol.ts`, on rest):
  `Authorization: Bearer`, `Accept: application/json`, base URL `api_base_url`;
  `{subscriptionId}` filled from `subscription_id` when the input leaves it out (an
  explicit one wins; none anywhere is a `ConfigError`, key `subscription_id`);
  `?api-version=` appended (after other query parameters; one already in the URL wins).
- **Errors** (`lua/distilled/azure/errors.lua` + `errors_data.lua`, port of `errors.ts`):
  180 classes, `AZURE_ERROR_CODE_MAP` (92 codes), `AZURE_ERROR_MESSAGE_MATCHERS` (125, in
  order). Failure order: message matchers, code map, a mapped `error.details[].code`,
  the HTTP status map (Retry-After on retryable statuses), unmapped 5xx ->
  `InternalServerError`, else `UnknownAzureError` (`code`, `message`, `target`, `body`).
  The ARM envelope `{ error: { code, message, target } }`, the flat shape, PascalCase
  `Code`/`Message` and a bare JSON string body are all read.
- **Success**: the body is the payload, plus the response headers the output declares
  (a 202's `Azure-AsyncOperation` / `Location` / `Retry-After`); an empty body is `{}`,
  `null` is `json.null`; sensitive members come back as secrets; strict validation and
  cut-off bodies fail with `AzureParseError` without the secret.
- **Credentials**: options are resolved on every request (`AZURE_BEARER_TOKEN`,
  `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_API_BASE_URL`). Added (Distilled
  takes a pre-acquired token only): Entra ID client credentials (`client_id`,
  `client_secret`, `tenant_id`, from `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` /
  `AZURE_TENANT_ID`; `authority_host`, `scope`), the token reused until 5 minutes before
  it expires; token sources `distilled.azure.credentials.cli()` (`az account
  get-access-token` through `host.exec`) and `.managed_identity()` (IMDS, or App
  Service's `IDENTITY_ENDPOINT`). A function source is resolved once and again after a
  401 that is `Unauthorized` (ARM's `ExpiredAuthenticationToken`).
- **Not done, as in Distilled**: no pagination (list operations return
  `{ value, nextLink }`; Distilled v0 emitted none), no long-running-operation polling
  (the 202's monitor headers are in the output).

## How a user reaches it

```lua
local Resources = require("azure.resources")
local client = Resources.new({
  bearer_token = token,          -- or $AZURE_BEARER_TOKEN, or client_id/client_secret/tenant_id
  subscription_id = sub,         -- or $AZURE_SUBSCRIPTION_ID
  host = require("distilled.host.popen")(),
})
local group, err = client:get_resource_group({ resourceGroupName = "my-rg" })
local page = client:list_resource_groups({ _filter = "tagName eq 'env'", _top = 5 })
-- page.value, page.nextLink

local azure_credentials = require("distilled.azure.credentials")
Resources.new({ bearer_token = azure_credentials.cli(), host = host })
```

## Driving it with `dl`

- `verify/dl test azure_` (all three runtimes): `azure_conform_spec` (1,170 requests and
  39 responses against Distilled's TS, and the error module), `azure_protocol_spec`
  (the port of `protocol.test.ts`, `errors.test.ts`, `response-headers.test.ts`, plus
  env per request, subscription rules, retries, token refresh, client credentials),
  `azure_credentials_spec`, `azure_gen_spec`.
- `verify/dl test --http azure_protocol`: one call through the real transport
  (popen_curl, Rex's exec_curl) against `dl serve`: a 429 retried, then the 202's
  headers; pending without `--http`.
- `verify/dl gen-diff azure`: regenerates all 223 models, diffs against `clients/azure`,
  `stylua --check`, and gen-check in lua, luajit and Rex (13,869/13,869 operations
  build; service load about 250 ms in lua/luajit and 1.4 s in Rex for all 223).
- `verify/dl azure-ref`: rewrites `spec/fixtures/azure/cases.json` (from the clients)
  and `spec/golden/azure/ref.json` (Distilled's answers, Node); a clean `git diff` after
  it means nothing drifted. `verify/dl azure-errors` rewrites
  `lua/distilled/azure/errors_data.lua` from Distilled's loaded `errors.ts`.

## Gotchas

- Intended differences from Distilled (normalised in `azure_conform_spec`): Lua errors
  from an HTTP failure also carry `status`, `body` and `headers` (and `code` on a
  status-map class); a message Distilled leaves undefined (it prints `""`) is
  `HTTP <status>` here; a parse error's message says what failed (Distilled: `""`).
- Distilled sets no `retryAfter` on a code-mapped class, so a 429 whose ARM code is
  mapped (`TooManyRequests` -> `RequestRateLimitExceeded`) is retried on backoff, not
  after its `Retry-After`; an unmapped code gets `TooManyRequests` with the hint. Kept.
- A 401 refreshes a function token only when it maps to `Unauthorized`: ARM's
  `InvalidAuthenticationToken` (and `...Audience`, `...Tenant`) are typed classes and do
  not trigger the refresh; `ExpiredAuthenticationToken` is unmapped and does.
- Azure docs end some lines with U+202F; the generator strips Unicode whitespace at line
  ends (`naming.rtrim`), or `stylua --check` fails on `postgresqlhsc/types.lua`.
- `clients/azure` is 78 MB (types.lua 42 MB, service data 39 MB, README 4 MB).
