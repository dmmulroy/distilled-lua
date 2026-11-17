// GCP conformance (task 21), step 2: what Distilled's GcpProtocol and
// GoogleWorkspaceProtocol make of every case in spec/fixtures/gcp/cases.json (written by
// verify/lib/gcp_conform_cases.lua). Writes spec/golden/gcp/reference.json, which
// spec/gcp_conform_spec.lua compares with the Lua clients in every runtime.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/gcp_conform.mjs
//
// Requests: API.encodeRequest (the request the protocol builds, not sent), with an access
// token, the case's quota project, Endpoint override and RegionalEndpoints mode.
// Responses and flows: the operation run against a scripted HttpClient, no retries, under
// the TestClock of verify/conform/node/outcome.mjs.
import * as fs from "node:fs";
import * as path from "node:path";
import { API, Effect, Layer, Redacted, Stream, DISTILLED, ROOT } from "../conform/node/distilled.mjs";
import { runVirtual, scripted, view, validationLayer } from "../conform/node/outcome.mjs";

const P = path.join(DISTILLED, "packages");
const Category = await import(path.join(P, "core/src/category.ts"));
const Duration = await import(path.join(P, "core/node_modules/effect/dist/Duration.js"));
const gcp = {
  Credentials: (await import(path.join(P, "gcp/src/credentials-service.ts"))).Credentials,
  Endpoint: await import(path.join(P, "gcp/src/endpoint.ts")),
  Region: await import(path.join(P, "gcp/src/region.ts")),
  Retry: await import(path.join(P, "gcp/src/retry.ts")),
  dir: "gcp",
};
const workspace = {
  Credentials: (await import(path.join(P, "google-workspace/src/credentials.ts"))).Credentials,
  Retry: await import(path.join(P, "google-workspace/src/retry.ts")),
  dir: "google-workspace",
};
const sdkOf = (pkg) => (pkg === "gcp" ? gcp : workspace);

export const TOKEN = "conform-token-0123";

// the Lua model name of a file stem (gen.lua_model_name: gamesConfiguration_v1configuration
// -> games_configuration_v1configuration)
const luaName = (stem) =>
  stem
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
const files = new Map();
const fileOf = (dir, service) => {
  if (!files.has(dir)) {
    const m = new Map();
    for (const f of fs.readdirSync(dir)) if (f.endsWith(".ts")) m.set(luaName(f.slice(0, -3)), f);
    files.set(dir, m);
  }
  return path.join(dir, files.get(dir).get(service) ?? `${service}.ts`);
};
const modules = new Map();
const moduleOf = async (c) => {
  const sdk = sdkOf(c.pkg);
  const file = fileOf(path.join(P, sdk.dir, "src", c.unstable ? "unstable-services" : "services"), c.service);
  if (!modules.has(file)) modules.set(file, await import(file));
  return modules.get(file);
};

/** JSON case value -> TS input: { "$secret": v } becomes Redacted. */
const toInput = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(toInput);
  const keys = Object.keys(v);
  if (keys.length === 1 && keys[0] === "$secret") return Redacted.make(v.$secret);
  const out = {};
  for (const k of keys) out[k] = toInput(v[k]);
  return out;
};

const layersOf = (c) => {
  const sdk = sdkOf(c.pkg);
  const o = c.options ?? {};
  const config = { accessToken: Redacted.make(TOKEN) };
  if (c.pkg === "gcp" && o.quota_project) config.quotaProject = o.quota_project;
  const layers = [Layer.succeed(sdk.Credentials, Effect.succeed(config))];
  if (c.pkg === "gcp" && o.endpoint !== undefined) layers.push(gcp.Endpoint.of(o.endpoint));
  if (c.pkg === "gcp" && o.regional_endpoints !== undefined)
    layers.push(gcp.Region.regionalEndpoints(o.regional_endpoints));
  layers.push(Layer.succeed(sdk.Retry.Retry, { while: () => false }));
  return layers;
};

const errorView = (e) => {
  if (e === null || typeof e !== "object") return { tag: String(e) };
  const cats = Object.keys(e[Category.categoriesKey] ?? {}).sort();
  const r = e[Category.retryableKey];
  const ra = e.retryAfter;
  return {
    tag: e._tag ?? e.constructor?.name,
    categories: cats,
    retryable: r !== undefined,
    throttling: r?.throttling === true,
    status: e.status,
    code: e.code,
    message: e.message,
    details: view(e.details),
    retry_after: ra === undefined ? undefined : Duration.toMillis(ra) / 1000,
    body: view(e.body),
  };
};
const outcomeOf = (result) =>
  result._tag === "Success"
    ? { ok: true, value: view(result.success) ?? null }
    : { ok: false, error: errorView(result.failure) };

const cases = JSON.parse(fs.readFileSync(path.join(ROOT, "spec/fixtures/gcp/cases.json"), "utf8"));
const reference = { requests: [], responses: [], flows: [] };

for (const c of cases.requests) {
  const mod = await moduleOf(c);
  const op = mod[c.ts];
  if (op === undefined) {
    reference.requests.push({ id: c.id, ok: false, error: { tag: "NoSuchOperation", message: c.ts } });
    continue;
  }
  const r = await Effect.runPromise(
    Effect.result(API.encodeRequest(op, toInput(c.input)).pipe(Effect.provide(Layer.mergeAll(...layersOf(c))))),
  );
  if (r._tag === "Success") {
    const req = r.success;
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(v);
    let body = null;
    if (req.body._tag === "Uint8Array") body = Buffer.from(req.body.body).toString("utf8");
    else if (req.body._tag !== "Empty") body = { other: req.body._tag };
    reference.requests.push({ id: c.id, ok: true, method: req.method, url: req.url, headers, body });
  } else {
    const e = r.failure;
    reference.requests.push({ id: c.id, ok: false, error: { tag: e?._tag ?? String(e), message: e?.message } });
  }
}

for (const c of cases.responses) {
  const mod = await moduleOf(c);
  const { layer } = scripted(() => c.response);
  const result = await runVirtual(mod[c.ts](toInput(c.input)), ...layersOf(c), layer, validationLayer(c.validation));
  reference.responses.push({ id: c.id, ...outcomeOf(result) });
}

for (const c of cases.flows) {
  const mod = await moduleOf(c);
  const { sent, layer } = scripted((n) => c.responses[n]);
  const stream = c.kind === "pages" ? mod[c.ts].pages(toInput(c.input)) : mod[c.ts].items(toInput(c.input));
  const result = await runVirtual(Stream.runCollect(stream), ...layersOf(c), layer);
  const outcome = outcomeOf(result);
  if (outcome.ok) outcome.value = Array.from(result.success).map(view);
  reference.flows.push({ id: c.id, urls: sent.map((s) => `${s.method} ${s.url}`), ...outcome });
}

const out = path.join(ROOT, "spec/golden/gcp/reference.json");
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(reference, null, 1) + "\n");
const failed = reference.requests.filter((r) => !r.ok).length;
console.log(
  `node: ${reference.requests.length} requests (${failed} failed to build), ${reference.responses.length} responses, ${reference.flows.length} flows -> ${out}`,
);
