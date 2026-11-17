// dl conform aws, the Node side: run each case of verify/conform/cases/aws.json through
// Distilled's generated AWS services (packages/aws/src/services/<service>.ts, imported by
// path, never modified) with a fake HttpClient, and write what each sent and returned to
// verify/conform/ref/aws/outcomes.json. verify/conform/aws_compare.lua diffs the Lua side.
//
//   node --conditions=bun --experimental-transform-types --no-warnings aws.mjs
//
// A case: { id, service, op, input, response: { status, headers, body } | absent }.
// The reference: { id, request: { method, url, headers, body }, outcome: { ok } | { error } }.
import * as fs from "node:fs";
import * as path from "node:path";
import { ROOT, DISTILLED, Effect, Layer, Redacted, Stream } from "./distilled.mjs";

const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");
const Exit = await import(E + "Exit.js");
const Credentials = await import(path.join(P, "s3/src/credentials.ts"));
const Retry = await import(path.join(P, "aws/src/retry.ts"));

const cases = JSON.parse(fs.readFileSync(path.join(ROOT, "verify/conform/cases/aws.json"), "utf8"));
const fromUtf8 = new TextDecoder();

const lowerFirst = (s) => s.charAt(0).toLowerCase() + s.slice(1);

// TS values in the form the Lua side compares: dates as epoch seconds, bytes as text,
// secrets unwrapped, undefined members dropped
const plainValue = async (v) => {
  if (v === null || v === undefined) return v;
  if (v instanceof Date) return v.getTime() / 1000;
  if (v instanceof Uint8Array) return { $bytes: fromUtf8.decode(v) };
  if (Redacted.isRedacted(v)) return plainValue(Redacted.value(v));
  if (Stream.isStream(v)) {
    const chunks = await Effect.runPromise(Stream.runCollect(v));
    return { $bytes: fromUtf8.decode(Buffer.concat(Array.from(chunks))) };
  }
  if (Array.isArray(v)) return Promise.all(v.map(plainValue));
  if (typeof v === "object") {
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      const p = await plainValue(x);
      if (p !== undefined) out[k] = p;
    }
    return out;
  }
  return v;
};

// case input -> TS input: { "$bytes": text } becomes a Uint8Array, { "$date": s } a Date
const toInput = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(toInput);
  const keys = Object.keys(v);
  if (keys.length === 1 && keys[0] === "$bytes") return new TextEncoder().encode(v.$bytes);
  if (keys.length === 1 && keys[0] === "$date") return new Date(v.$date * 1000);
  const out = {};
  for (const k of keys) out[k] = toInput(v[k]);
  return out;
};

const bodyText = async (request) => {
  const body = request.body;
  switch (body._tag) {
    case "Empty":
      return "";
    case "Uint8Array":
      return fromUtf8.decode(body.body);
    case "Raw":
      return typeof body.body === "string"
        ? body.body
        : body.body instanceof Uint8Array
          ? fromUtf8.decode(body.body)
          : await new Response(body.body).text();
    case "Stream": {
      const chunks = await Effect.runPromise(Stream.runCollect(body.stream));
      return fromUtf8.decode(Buffer.concat(Array.from(chunks)));
    }
    default:
      return `<${body._tag} body>`;
  }
};

const modules = {};
const out = [];
for (const c of cases) {
  modules[c.service] ??= await import(path.join(P, "aws/src/services", `${c.service}.ts`));
  const fn = modules[c.service][lowerFirst(c.op)];
  if (typeof fn !== "function") throw new Error(`${c.service} exports no ${lowerFirst(c.op)}`);
  let sent;
  const canned = c.response ?? { status: 200, headers: {}, body: "" };
  const client = HttpClient.make((request) =>
    Effect.sync(() => {
      sent = request;
      const empty = canned.status === 204 || canned.status === 304 || !canned.body;
      return HttpClientResponse.fromWeb(
        request,
        new Response(empty ? null : canned.body, { status: canned.status, headers: canned.headers }),
      );
    }),
  );
  const creds = Layer.succeed(
    Credentials.Credentials,
    Effect.succeed({
      accessKeyId: Redacted.make("AKIDEXAMPLE"),
      secretAccessKey: Redacted.make("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
      sessionToken: undefined,
      region: c.region ?? "us-east-1",
    }),
  );
  const exit = await Effect.runPromiseExit(
    Effect.suspend(() => fn(toInput(c.input ?? {}))).pipe(
      Retry.none,
      Effect.provide(Layer.mergeAll(creds, Layer.succeed(HttpClient.HttpClient, client))),
    ),
  );
  const entry = { id: c.id };
  if (sent) {
    const headers = {};
    for (const [k, v] of Object.entries(sent.headers)) headers[k.toLowerCase()] = v;
    const params = sent.urlParams.params.map(([k, v]) => [k, typeof v === "string" ? v : Redacted.value(v)]);
    entry.request = { method: sent.method, url: sent.url, params, headers, body: await bodyText(sent) };
  }
  if (Exit.isSuccess(exit)) {
    entry.outcome = { ok: (await plainValue(exit.value)) ?? {} };
  } else {
    const reason = exit.cause.reasons.find((r) => r._tag === "Fail");
    const e = reason?.error;
    if (e === undefined) {
      entry.outcome = { defect: String(exit.cause) };
    } else {
      const fields = {};
      for (const [k, v] of Object.entries(e)) {
        if (k !== "stack" && k !== "_tag" && k !== "cause") fields[k] = await plainValue(v);
      }
      entry.outcome = { error: { tag: e._tag, message: e.message, fields } };
    }
  }
  out.push(entry);
}

const dir = path.join(ROOT, "verify/conform/ref/aws");
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, "outcomes.json"), JSON.stringify(out, null, 1) + "\n");
console.log(`aws: ${out.length} cases -> verify/conform/ref/aws/outcomes.json`);
