// Writes spec/golden/azure/ref.json: what Distilled's Azure SDK
// (../distilled/packages/azure, the code distilled.protocol.azure ports) does, for
// spec/azure_conform_spec.lua to compare in lua, luajit and Rex:
//
// - requests: every case of spec/fixtures/azure/cases.json (written by
//   verify/lib/azure_cases.lua from the generated clients) built with API.encodeRequest
//   (the operation's protocol, no send): method, URL, headers, body;
// - responses: the RESPONSES below (Distilled's protocol.test.ts, errors.test.ts and
//   response-headers.test.ts cases plus more) run over a stub HttpClient with retries
//   off: the outcome (value, or the error's tag, categories, retryable, code, message,
//   target, retry_after, body);
// - errors: the error module itself (each class's categories and retryable flag, the
//   code map and the message matchers) as Distilled exports it.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/azure_ref.mjs spec/golden/azure/ref.json
// (`verify/dl azure-ref` runs it after azure_cases.lua). DISTILLED_ROOT overrides ../distilled.
import * as path from "node:path";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const AZ = path.join(P, "azure/src");
const Azure = await import(path.join(AZ, "index.ts"));
const API = await import(path.join(P, "core/src/api.ts"));
const Category = await import(path.join(P, "core/src/category.ts"));
const RV = await import(path.join(P, "core/src/response-validation.ts"));
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Duration = await import(E + "Duration.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");

const out = process.argv[2];
if (!out) throw new Error("usage: azure_ref.mjs <out.json>");

const EPOCH_MS = 1700000000000;
Date.now = () => EPOCH_MS;
Math.random = () => 0.5;

export const TOKEN = "conform-arm-token-7f3a";
export const SUBSCRIPTION = "00000000-0000-0000-0000-00000000c0f1";
export const BASE_URL = "https://management.conform.test";

const credentials = Layer.succeed(
  Azure.Credentials,
  Effect.succeed({
    bearerToken: Redacted.make(TOKEN),
    subscriptionId: SUBSCRIPTION,
    apiBaseUrl: BASE_URL,
  }),
);
const noRetry = Layer.succeed(Azure.Retry.Retry, { while: () => false });

const modules = new Map();
const service = async (model) => {
  if (!modules.has(model)) modules.set(model, await import(path.join(AZ, "services", `${model}.ts`)));
  return modules.get(model);
};

const sortKeys = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(sortKeys);
  const o = {};
  for (const k of Object.keys(v).sort()) o[k] = sortKeys(v[k]);
  return o;
};

// ---------------------------------------------------------------------------------
// requests
// ---------------------------------------------------------------------------------

const bodyOf = (body) => {
  switch (body._tag) {
    case "Empty":
      return { kind: "none" };
    case "Uint8Array":
      return { kind: "bytes", text: new TextDecoder().decode(body.body), content_type: body.contentType };
    case "Raw":
    case "Text":
      return { kind: "bytes", text: String(body.body), content_type: body.contentType };
    default:
      return { kind: "other", tag: body._tag };
  }
};

const cases = JSON.parse(readFileSync(path.join(ROOT, "spec/fixtures/azure/cases.json"), "utf8"));
const requests = [];
let missing = 0;
for (const c of cases) {
  const mod = await service(c.model);
  const op = mod[c.ts];
  if (op === undefined) {
    requests.push({ id: c.id, ok: false, error: { tag: "NoSuchOperation", message: c.ts } });
    missing++;
    continue;
  }
  const r = await Effect.runPromise(
    Effect.result(API.encodeRequest(op, c.input).pipe(Effect.provide(credentials))),
  );
  if (r._tag === "Success") {
    const req = r.success;
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(v);
    requests.push({ id: c.id, ok: true, method: req.method, url: req.url, headers, body: bodyOf(req.body) });
  } else {
    const e = r.failure;
    requests.push({ id: c.id, ok: false, error: { tag: e?._tag ?? String(e), message: e?.message } });
  }
}

// ---------------------------------------------------------------------------------
// responses
// ---------------------------------------------------------------------------------

const SECRET = "sentinel-secret-7f3a";
const rg = { subscriptionId: SUBSCRIPTION, resourceGroupName: "my-rg" };
const arm = (code, message, extra = {}) => JSON.stringify({ error: { code, message, ...extra } });
const getRg = { model: "resources", ts: "GetResourceGroup", method: "get_resource_group", input: rg };
const delRg = { model: "resources", ts: "DeleteResourceGroup", method: "delete_resource_group", input: rg };
const regenKey = {
  model: "appconfiguration",
  ts: "RegenerateConfigurationStoreKey",
  method: "regenerate_configuration_store_key",
  input: { subscriptionId: SUBSCRIPTION, resourceGroupName: "rg", configStoreName: "store", id: "k" },
};
const monitor = `https://management.azure.com/subscriptions/${SUBSCRIPTION}/providers/Microsoft.DBforPostgreSQL/locations/northcentralus/azureAsyncOperation/5dfd3b67?api-version=2025-08-01`;
const results = `https://management.azure.com/subscriptions/${SUBSCRIPTION}/providers/Microsoft.DBforPostgreSQL/locations/northcentralus/operationResults/5dfd3b67?api-version=2025-08-01`;

const RESPONSES = [
  // protocol.test.ts: ARM error envelope decoding
  { id: "code_map_with_target", ...getRg, status: 404, body: arm("ResourceGroupNotFound", "Resource group 'my-rg' could not be found.", { target: "my-rg" }) },
  { id: "flat_code_message", ...getRg, status: 401, body: JSON.stringify({ code: "InvalidAuthenticationToken", message: "expired" }) },
  { id: "pascal_case", ...getRg, status: 404, body: JSON.stringify({ Code: "ResourceNotFound", Message: "The resource was not found." }) },
  { id: "message_matcher_wins", ...getRg, status: 409, body: arm("409", "The managed HSM pool is still updating its spec. Retry later.") },
  { id: "details_code", ...getRg, status: 400, body: arm("ValidationError", "Validation failed", { target: "t", details: [{ code: "SomethingUnmapped", message: "ignored" }, { code: "ResourceNotFound", message: "The parent was not found." }] }) },
  { id: "details_code_no_message", ...getRg, status: 400, body: arm("ValidationError", "Validation failed", { details: [{ code: "ResourceNotFound" }] }) },
  { id: "unmapped_code_status", ...getRg, status: 404, body: arm("SomeNewCode", "Gone fishing") },
  { id: "retry_after_429", ...getRg, status: 429, body: arm("SomeThrottle", "slow down"), headers: { "retry-after": "12" } },
  { id: "retry_after_503_date", ...getRg, status: 503, body: arm("Busy", "later"), headers: { "retry-after": "Tue, 14 Nov 2023 22:14:00 GMT" } },
  { id: "non_json_trimmed", ...getRg, status: 404, body: "  <html>not here</html>\n" },
  { id: "bare_json_string", ...getRg, status: 418, body: JSON.stringify("Guest configuration says no") },
  { id: "unmapped_5xx_empty", ...getRg, status: 507, body: "" },
  { id: "unmapped_5xx_message", ...getRg, status: 599, body: arm("Weird", "odd gateway") },
  { id: "unknown_4xx", ...getRg, status: 418, body: JSON.stringify({ error: { code: "Teapot", message: "short and stout", target: "pot" } }) },
  { id: "unknown_4xx_no_message", ...getRg, status: 418, body: JSON.stringify({ error: { code: "Teapot" } }) },
  { id: "status_empty_body", ...getRg, status: 404, body: "" },
  { id: "status_empty_object", ...getRg, status: 403, body: "{}" },
  { id: "error_string_field", ...getRg, status: 400, body: JSON.stringify({ error: "invalid_request", code: "InvalidParameter", message: "bad" }) },
  { id: "throttling_code", ...getRg, status: 429, body: arm("TooManyRequests", "slow"), headers: { "retry-after": "3" } },
  { id: "quota_code", ...getRg, status: 409, body: arm("QuotaExceeded", "no more") },
  { id: "auth_class_no_target", ...getRg, status: 403, body: arm("AuthorizationFailed", "denied", { target: "x" }) },
  { id: "retryable_class", ...getRg, status: 500, body: arm("NetAppVolumeGroupNotReadable", "x") },
  { id: "expired_token", ...getRg, status: 401, body: arm("ExpiredAuthenticationToken", "The access token expiry UTC time is earlier than current UTC time.") },
  // errors.test.ts (recorded from ARM)
  { id: "parameter_out_of_range", model: "postgresql", ts: "ServersCreateOrUpdate", method: "servers_create_or_update", input: { subscriptionId: SUBSCRIPTION, resourceGroupName: "rg", serverName: "pg", location: "centralus" }, status: 400, body: JSON.stringify({ error: { code: "ParameterOutOfRange", message: "The value of the 'Version' should be in: [11,12,13,14,15,16,17,18]. Verify that the specified parameter value is correct." } }) },
  { id: "location_not_available", model: "resources", ts: "ResourceGroupsCreateOrUpdate", method: "resource_groups_create_or_update", input: { subscriptionId: SUBSCRIPTION, resourceGroupName: "rg", location: "nowhere" }, status: 400, body: JSON.stringify({ error: { code: "LocationNotAvailableForResourceGroup", message: "The provided location 'nowhere' is not available for resource group. List of available regions is 'eastasia,southeastasia,centralus'." } }) },
  // success decoding
  { id: "payload", ...getRg, status: 200, body: JSON.stringify({ id: "/x", name: "my-rg", location: "westus", tags: { env: "prod" } }) },
  { id: "empty_202_headers", ...delRg, status: 202, body: "", headers: { location: "https://poll" } },
  { id: "empty_204", ...delRg, status: 204, body: null },
  { id: "empty_200", ...delRg, status: 200, body: "" },
  { id: "json_null", ...delRg, status: 200, body: "null" },
  { id: "sensitive_output", ...regenKey, status: 200, body: JSON.stringify({ id: "k", connectionString: "Endpoint=secret", readOnly: true }) },
  { id: "strict_mismatch", ...getRg, status: 200, body: JSON.stringify({ name: "rg" }), validation: "strict" },
  { id: "cut_secret_lenient", ...regenKey, status: 200, body: `{"id":"k","connectionString":"${SECRET}` },
  { id: "cut_secret_strict", ...regenKey, status: 200, body: `{"id":"k","connectionString":"${SECRET}`, validation: "strict" },
  { id: "strict_sensitive_mismatch", ...regenKey, status: 200, body: JSON.stringify({ connectionString: SECRET, readOnly: "no" }), validation: "strict" },
  { id: "strict_secret_offender", ...regenKey, status: 200, body: JSON.stringify({ connectionString: "c", readOnly: SECRET }), validation: "strict" },
  { id: "list_next_link", model: "resources", ts: "ListResourceGroups", method: "list_resource_groups", input: { subscriptionId: SUBSCRIPTION }, status: 200, body: JSON.stringify({ value: [{ id: "/a", name: "a", location: "westus" }], nextLink: "https://management.azure.com/next?$skiptoken=abc" }) },
  // response-headers.test.ts (recorded from ARM)
  { id: "lro_202_monitor", model: "postgresql", ts: "UpdateServer", method: "update_server", input: { subscriptionId: SUBSCRIPTION, resourceGroupName: "rg", serverName: "pg", properties: { createMode: "Update", version: "17" } }, status: 202, headers: { "content-type": "application/json", "azure-asyncoperation": monitor, location: results, "retry-after": "60" }, body: JSON.stringify({ operation: "UpsertServerManagementOperationV2", startTime: "2026-10-01T20:47:48.6Z" }) },
  { id: "location_header_suffix", model: "azure_kusto", ts: "AttachedDatabaseConfigurationsCreateOrUpdate", method: "attached_database_configurations_create_or_update", input: { subscriptionId: SUBSCRIPTION, resourceGroupName: "rg", clusterName: "kusto", attachedDatabaseConfigurationName: "attached", location: "westus" }, status: 200, headers: { "content-type": "application/json", location: results }, body: JSON.stringify({ name: "attached", location: "West US" }) },
];

const view = (v) => {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object") return v;
  if (Redacted.isRedacted(v)) return { $redacted: view(Redacted.value(v)) };
  if (Array.isArray(v)) return v.map(view);
  const o = {};
  for (const [k, x] of Object.entries(v)) if (x !== undefined) o[k] = view(x);
  return o;
};

const errorView = (e) => {
  const cats = Object.keys(e[Category.categoriesKey] ?? {}).sort();
  const r = e[Category.retryableKey];
  const ra = e.retryAfter;
  return {
    tag: e._tag,
    categories: cats,
    retryable: r !== undefined,
    throttling: r?.throttling === true,
    status: e.status,
    code: e.code,
    message: e.message,
    target: e.target,
    retry_after: ra === undefined ? undefined : Duration.toMillis(ra) / 1000,
    body: view(e.body),
  };
};

const responses = [];
for (const c of RESPONSES) {
  const mod = await service(c.model);
  const op = mod[c.ts];
  if (op === undefined) throw new Error(`no operation ${c.model}.${c.ts}`);
  const status = c.status;
  const nullBody = status === 204 || status === 205 || status === 304;
  const http = Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() =>
        HttpClientResponse.fromWeb(
          request,
          new Response(nullBody ? null : c.body, { status, headers: c.headers ?? {} }),
        ),
      ),
    ),
  );
  const mode = c.validation === "strict" ? RV.strict : RV.lenient;
  const r = await Effect.runPromise(
    Effect.result(
      op(c.input).pipe(Effect.provide(Layer.mergeAll(credentials, http, noRetry, mode))),
    ),
  );
  const { id, model, ts, method, input, status: st, headers, body, validation } = c;
  const outcome =
    r._tag === "Success"
      ? { ok: true, value: view(r.success) ?? null }
      : { ok: false, error: errorView(r.failure) };
  responses.push({ id, model, method, ts, input, status: st, headers, body, validation, outcome });
}

// ---------------------------------------------------------------------------------
// the error module
// ---------------------------------------------------------------------------------

const coreClasses = new Set(Object.values(await import(path.join(P, "core/src/errors.ts"))));
const classes = {};
for (const [name, v] of Object.entries(Azure)) {
  if (typeof v !== "function" || coreClasses.has(v) || !v.fields) continue;
  const cats = Object.keys(v.prototype[Category.categoriesKey] ?? {}).sort();
  const r = v.prototype[Category.retryableKey];
  classes[name] = { categories: cats, retryable: r !== undefined, throttling: r?.throttling === true, fields: Object.keys(v.fields).sort() };
}
const codes = {};
for (const [code, C] of Object.entries(Azure.AZURE_ERROR_CODE_MAP)) codes[code] = new C({})._tag;
const matchers = Azure.AZURE_ERROR_MESSAGE_MATCHERS.map((m) => ({ code: m.code, includes: m.includes, tag: new m.error({})._tag }));

mkdirSync(path.dirname(out), { recursive: true });
const doc = sortKeys({
  token: TOKEN,
  subscription: SUBSCRIPTION,
  base_url: BASE_URL,
  requests,
  responses,
  errors: { classes, codes },
});
doc.errors.matchers = matchers; // order matters: the first matching matcher wins
writeFileSync(out, JSON.stringify(doc, null, 1) + "\n");
console.log(
  `wrote ${out}: ${requests.length} requests (${missing} operations missing in Distilled), ` +
    `${responses.length} responses, ${Object.keys(classes).length} classes`,
);
