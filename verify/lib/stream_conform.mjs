// Writes spec/golden/stream/boat.json: what Distilled's TS does with canned NDJSON replies
// for Boat's two streaming operations, for spec/stream_conform_spec.lua to compare with
// clients/boat_dev (task 29).
//
//   executeSandboxCommand.stream(input)  (API.makeStreaming, streamInput { stream: true },
//                                         items CommandStreamFrame, core/ndjson framing)
//   attachCommand.stream(input)          (serverStreaming, items of the output's `items`)
//   attachCommand(input)                 (the plain call collects the NDJSON lines)
//
// Each case records the request (method, URL, headers, body) and every item, or the error
// the stream ends with. Replies are chunks (text), so lines split across chunks too.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/stream_conform.mjs spec/golden/stream/boat.json
import * as path from "node:path";
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const out = process.argv[2];
if (!out) throw new Error("usage: stream_conform.mjs <out.json>");

const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Stream = await import(E + "Stream.js");
const Redacted = await import(E + "Redacted.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");
const Category = await import(path.join(P, "core/src/category.ts"));

const BOAT = {
  svc: await import(path.join(P, "boat-dev/src/services/boat.ts")),
  creds: await import(path.join(P, "boat-dev/src/credentials.ts")),
  retry: await import(path.join(P, "boat-dev/src/retry.ts")),
};

const errView = (e) => {
  if (e === null || typeof e !== "object") return { defect: String(e) };
  const fields = {};
  for (const k of ["status", "code"]) if (e[k] !== undefined) fields[k] = e[k];
  return {
    tag: e._tag ?? e.constructor?.name,
    message: typeof e.message === "string" ? e.message : undefined,
    categories: Object.keys(e[Category.categoriesKey] ?? {}).sort(),
    fields,
  };
};

const toJson = (v) =>
  JSON.parse(
    JSON.stringify(v, (_k, x) => {
      if (Redacted.isRedacted?.(x)) return { redacted: Redacted.value(x) };
      return x === undefined ? null : x;
    }),
  );

const stub = (reply, sent) =>
  Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() => {
        const body = request.body;
        sent.push({
          method: request.method,
          url: request.url,
          headers: { ...request.headers },
          body: body._tag === "Uint8Array" ? Buffer.from(body.body).toString("utf8") : null,
        });
        const stream = new ReadableStream({
          start(controller) {
            for (const c of reply.chunks) controller.enqueue(new TextEncoder().encode(c));
            controller.close();
          },
        });
        return HttpClientResponse.fromWeb(
          request,
          new Response(stream, { status: reply.status, headers: reply.headers ?? {} }),
        );
      }),
    ),
  );

const layer = (reply, sent) =>
  Layer.mergeAll(
    Layer.succeed(
      BOAT.creds.Credentials,
      Effect.succeed({ apiKey: Redacted.make("boat_key"), apiBaseUrl: "https://boat.test/api/v1" }),
    ),
    Layer.succeed(BOAT.retry.Retry, { while: () => false }),
    stub(reply, sent),
  );

const drain = async (stream, l) => {
  const items = [];
  const result = await Effect.runPromise(
    Effect.result(Stream.runForEach(stream, (x) => Effect.sync(() => items.push(toJson(x))))).pipe(
      Effect.provide(l),
    ),
  );
  const r = { items };
  if (result._tag === "Failure") r.error = errView(result.failure);
  return r;
};

const call = async (effect, l) => {
  const result = await Effect.runPromise(Effect.result(effect).pipe(Effect.provide(l)));
  return result._tag === "Failure" ? { error: errView(result.failure) } : { value: toJson(result.success) };
};

const ND = { "content-type": "application/x-ndjson" };
const EXEC = { sandboxId: "sb1", command: "echo hi", cwd: "/w", timeoutSeconds: 30 };
const ATTACH = { sandboxId: "sb1", processId: 7, stdoutOffset: 10 };

const cases = [
  {
    name: "exec: started, output, exit",
    op: "execute_sandbox_command",
    mode: "stream",
    input: EXEC,
    reply: {
      status: 200,
      headers: ND,
      chunks: [
        '{"type":"started","commandId":"c1"}\n',
        '{"type":"stdout","data":"hi\\n"}\n{"type":"stderr",',
        '"data":"warn"}\r\n\n',
        '{"type":"exit","exitCode":0,"success":true,"signal":null,"timedOut":false}\n',
      ],
    },
  },
  {
    name: "exec: error frame, unknown member kept",
    op: "execute_sandbox_command",
    mode: "stream",
    input: { sandboxId: "sb1", command: "x", stream: false },
    reply: {
      status: 200,
      headers: ND,
      chunks: ['{"type":"error","error":"boom","message":"failed","retryable":false,"extra":1}'],
    },
  },
  {
    name: "exec: a line that is not JSON",
    op: "execute_sandbox_command",
    mode: "stream",
    input: EXEC,
    reply: { status: 200, headers: ND, chunks: ['{"type":"started"}\n', "oops\n", '{"type":"exit"}\n'] },
  },
  {
    name: "exec: 409 sandbox not running",
    op: "execute_sandbox_command",
    mode: "stream",
    input: EXEC,
    reply: {
      status: 409,
      headers: { "content-type": "application/json" },
      chunks: ['{"code":"sandbox_not_running","message":"stopped"}'],
    },
  },
  {
    name: "exec: 404",
    op: "execute_sandbox_command",
    mode: "stream",
    input: EXEC,
    reply: {
      status: 404,
      headers: { "content-type": "application/json" },
      chunks: ['{"code":"not_found","message":"no sandbox"}'],
    },
  },
  {
    name: "attach: attached, chunks, exit",
    op: "attach_command",
    mode: "stream",
    input: ATTACH,
    reply: {
      status: 200,
      headers: ND,
      chunks: [
        '{"type":"attached","processId":7,"stdoutOffset":10,"stderrOffset":0}\n',
        '{"type":"stdout","data":"x","nextOffset":11}\n',
        '{"type":"heartbeat"}\n{"type":"exit","status":"exited","exitCode":0,"signal":null}\n',
      ],
    },
  },
  {
    name: "attach: plain call collects the lines",
    op: "attach_command",
    mode: "call",
    input: ATTACH,
    reply: {
      status: 200,
      headers: ND,
      chunks: ['{"type":"attached","processId":7}\n', '{"type":"reconnect","stdoutOffset":99}\n'],
    },
  },
  {
    name: "attach: empty stream",
    op: "attach_command",
    mode: "stream",
    input: ATTACH,
    reply: { status: 200, headers: ND, chunks: [] },
  },
];

const FN = { execute_sandbox_command: "executeSandboxCommand", attach_command: "attachCommand" };
const results = [];
for (const c of cases) {
  const sent = [];
  const l = layer(c.reply, sent);
  const op = BOAT.svc[FN[c.op]];
  const r = c.mode === "stream" ? await drain(op.stream(c.input), l) : await call(op(c.input), l);
  results.push({ ...c, sent, ...r });
}

mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(results, null, 1) + "\n");
console.log(`wrote ${out}: ${results.length} cases`);
