// Cloudflare conformance (task 19), the Node side: answers every case of cases.jsonl with
// Distilled's TypeScript SDK (packages/cloudflare, imported by path, never modified).
//   node --conditions=bun --experimental-transform-types --no-warnings verify/conform/cloudflare/ts.mjs
// writes verify/conform/cloudflare/ref.jsonl:
//   request:  { id, ok, method, url, headers, body: { kind, text?, b64?, parts? } } | { id, ok: false, error }
//   response: { id, outcome: { ok, value } | { ok: false, error: { tag, message, code, transient, ... } } }
//   flow:     { id, urls: [...], outcome: { ok, value: items } | { ok: false, error } }
import * as path from "node:path";
import * as fs from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const CF = await import(path.join(P, "cloudflare/src/index.ts"));
const API = await import(path.join(P, "core/src/api.ts"));
const Category = await import(path.join(P, "core/src/category.ts"));
const RV = await import(path.join(P, "core/src/response-validation.ts"));
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Duration = await import(E + "Duration.js");
const Stream = await import(E + "Stream.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");

const TOKEN = "cf-conform-token";
const creds = CF.fromApiToken({ apiToken: Redacted.make(TOKEN) });
const noRetry = Layer.succeed(CF.Retry.Retry, { while: () => false });
const validationLayer = (mode) =>
  mode === "strict" ? RV.strict : mode === "additional" ? RV.additionalProperties : RV.lenient;

const readLines = (file) =>
  fs.readFileSync(file, "utf8").split("\n").filter((l) => l.length > 0).map((l) => JSON.parse(l));

const bytesOf = (buf) => {
  const text = buf.toString("utf8");
  return Buffer.from(text, "utf8").equals(buf) ? { text } : { b64: buf.toString("base64") };
};

const bodyOf = async (body) => {
  switch (body._tag) {
    case "Empty":
      return { kind: "none" };
    case "Uint8Array":
      return { kind: "bytes", ...bytesOf(Buffer.from(body.body)), content_type: body.contentType };
    case "Raw":
    case "Text":
      return { kind: "bytes", ...bytesOf(Buffer.from(String(body.body))), content_type: body.contentType };
    case "FormData": {
      const parts = [];
      for (const [name, value] of body.formData.entries()) {
        if (typeof value === "string") parts.push({ name, value });
        else
          parts.push({
            name,
            filename: value.name,
            content_type: value.type,
            ...bytesOf(Buffer.from(await value.arrayBuffer())),
          });
      }
      return { kind: "multipart", parts };
    }
    default:
      return { kind: "other", tag: body._tag };
  }
};

const view = (v) => {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object") return v;
  if (Redacted.isRedacted(v)) return { $redacted: view(Redacted.value(v)) };
  if (v instanceof Uint8Array) return { $bytes_b64: Buffer.from(v).toString("base64") };
  if (Array.isArray(v)) return v.map(view);
  const out = {};
  for (const [k, x] of Object.entries(v)) if (x !== undefined) out[k] = view(x);
  return out;
};

const errorView = (e) => {
  if (e === null || typeof e !== "object") return { tag: String(e) };
  const ra = e.retryAfter;
  return {
    tag: e._tag ?? e.constructor?.name,
    message: e.message,
    code: typeof e.code === "number" ? e.code : undefined,
    transient: Category.isTransientError(e),
    throttling: Category.isThrottlingError ? Category.isThrottlingError(e) : undefined,
    retry_after: ra === undefined ? undefined : Duration.toMillis(ra) / 1000,
    // a validation failure's SchemaMismatch (CloudflareParseError.cause)
    cause_path: Array.isArray(e.cause?.path) ? e.cause.path.map((k) => (typeof k === "number" ? k : String(k))) : undefined,
    cause_expected: typeof e.cause?.expected === "string" ? e.cause.expected : undefined,
  };
};

const outcomeOf = (result) =>
  result._tag === "Success"
    ? { ok: true, value: view(result.success) ?? null }
    : { ok: false, error: errorView(result.failure) };

const scripted = (replies) => {
  const urls = [];
  const layer = Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() => {
        urls.push(request.url);
        const r = replies[Math.min(urls.length - 1, replies.length - 1)];
        const status = r.status ?? 200;
        const nullBody = status === 204 || status === 205 || status === 304;
        return HttpClientResponse.fromWeb(
          request,
          new Response(nullBody ? null : r.body ?? "", { status, headers: r.headers ?? {} }),
        );
      }),
    ),
  );
  return { urls, layer };
};

const modules = new Map();
const serviceOf = async (model) => {
  if (!modules.has(model))
    modules.set(model, await import(path.join(P, "cloudflare/src/services", model + ".ts")));
  return modules.get(model);
};

const cases = readLines(process.env.CF_CASES ?? path.join(here, "cases.jsonl"));
const out = [];
let missing = 0;
for (const c of cases) {
  const svc = await serviceOf(c.model);
  const op = svc[c.ts];
  if (op === undefined) {
    out.push({ id: c.id, missing: true });
    missing++;
    continue;
  }
  const layers = [creds, noRetry, validationLayer(c.validation)];
  if (c.jurisdiction) layers.push(CF.Jurisdiction.of(c.jurisdiction));
  if (c.kind === "request") {
    const r = await Effect.runPromise(
      Effect.result(API.encodeRequest(op, c.input_ts).pipe(Effect.provide(Layer.mergeAll(...layers)))),
    );
    if (r._tag === "Success") {
      const req = r.success;
      const headers = {};
      for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(v);
      out.push({ id: c.id, ok: true, method: req.method, url: req.url, headers, body: await bodyOf(req.body) });
    } else {
      out.push({ id: c.id, ok: false, error: errorView(r.failure) });
    }
  } else if (c.kind === "response") {
    const http = scripted(c.replies);
    const r = await Effect.runPromise(
      Effect.result(op(c.input_ts)).pipe(Effect.provide(Layer.mergeAll(http.layer, ...layers))),
    );
    out.push({ id: c.id, outcome: outcomeOf(r) });
  } else if (c.kind === "flow") {
    const http = scripted(c.replies);
    const r = await Effect.runPromise(
      Effect.result(Stream.runCollect(op.items(c.input_ts))).pipe(
        Effect.provide(Layer.mergeAll(http.layer, ...layers)),
      ),
    );
    const outcome =
      r._tag === "Success" ? { ok: true, value: view(Array.from(r.success)) } : outcomeOf(r);
    out.push({ id: c.id, urls: http.urls, outcome });
  }
}
fs.writeFileSync(process.env.CF_REF ?? path.join(here, "ref.jsonl"), out.map((v) => JSON.stringify(v)).join("\n") + "\n");
console.log(`node: ${out.length} cloudflare cases answered by Distilled (${missing} operations not found)`);
