// Writes spec/golden/grpc_stream/conform.json: what Distilled's TS does with canned
// streamed replies, for spec/grpc_stream_conform_spec.lua to compare with the Lua clients.
//
//   boxd   StreamLogs through `streamLogs.stream(input)` (core protocol-grpc.ts
//          streamReply, gRPC-Web): the request (URL, headers, body bytes) and every item
//          or the error the stream ends with
//   e2b    packages/e2b/src/connect.ts startProcess / connectProcess / watchDir over a
//          stub HttpClient: the request and the events or the error
//
// Replies are given as chunks (base64) so frames split across chunk boundaries too.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/grpc_stream_conform.mjs spec/golden/grpc_stream/conform.json
import * as path from "node:path";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const out = process.argv[2];
if (!out) throw new Error("usage: grpc_stream_conform.mjs <out.json>");

const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Stream = await import(E + "Stream.js");
const Redacted = await import(E + "Redacted.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");
const Category = await import(path.join(P, "core/src/category.ts"));
const pb = await import(path.join(P, "core/src/protobuf.ts"));

const BOXD = {
  svc: await import(path.join(P, "boxd/src/services/boxd.ts")),
  creds: await import(path.join(P, "boxd/src/credentials.ts")),
  retry: await import(path.join(P, "boxd/src/retry.ts")),
  d: (await import(path.join(P, "boxd/src/descriptors.ts"))).descriptors,
};
const E2B = {
  connect: await import(path.join(P, "e2b/src/connect.ts")),
  creds: await import(path.join(P, "e2b/src/credentials.ts")),
};

const b64 = (u8) => Buffer.from(u8).toString("base64");

const frame = (payload, flag = 0) => {
  const out = new Uint8Array(5 + payload.length);
  out[0] = flag;
  new DataView(out.buffer).setUint32(1, payload.length, false);
  out.set(payload, 5);
  return out;
};
const cat = (...parts) => Buffer.concat(parts.map((p) => Buffer.from(p)));
const msgFrame = (type, value) => frame(pb.encodeMessage(BOXD.d, type, value));
const webTrailer = (text) => frame(Buffer.from(text, "utf8"), 0x80);
const envelope = (value, flag = 0) => frame(Buffer.from(JSON.stringify(value), "utf8"), flag);

// splits bytes into chunks of `size` (0: one chunk)
const chunked = (bytes, size) => {
  const buf = Buffer.from(bytes);
  if (!size) return [buf];
  const out = [];
  for (let i = 0; i < buf.length; i += size) out.push(buf.subarray(i, i + size));
  return out;
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
      if (x instanceof Uint8Array) return { bytes_b64: b64(x) };
      if (Redacted.isRedacted?.(x)) return { redacted: Redacted.value(x) };
      return x;
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
          body_b64: body._tag === "Uint8Array" ? b64(body.body) : null,
          content_type: body.contentType,
        });
        const chunks = reply.chunks.map((c) => Buffer.from(c, "base64"));
        const stream = new ReadableStream({
          start(controller) {
            for (const c of chunks) controller.enqueue(new Uint8Array(c));
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

const drain = async (stream, layer) => {
  const items = [];
  const result = await Effect.runPromise(
    Effect.result(Stream.runForEach(stream, (x) => Effect.sync(() => items.push(toJson(x))))).pipe(
      Effect.provide(layer),
    ),
  );
  const r = { items };
  if (result._tag === "Failure") r.error = errView(result.failure);
  return r;
};

const cases = [];

// --- boxd: gRPC-Web StreamLogs --------------------------------------------------------

const boxdLayer = (reply, sent) =>
  Layer.mergeAll(
    Layer.succeed(
      BOXD.creds.Credentials,
      Effect.succeed({ token: Redacted.make("bxd_tok"), apiBaseUrl: "https://boxd.test" }),
    ),
    Layer.succeed(BOXD.retry.Retry, { while: () => false }),
    stub(reply, sent),
  );

const WEB = { "content-type": "application/grpc-web+proto" };
const chunk = (data, extra = {}) =>
  msgFrame("boxd.api.v1.LogChunk", { data: b64(Buffer.from(data)), ...extra });

const boxdCases = [
  {
    name: "two chunks then an OK trailer frame",
    reply: { status: 200, headers: WEB, body: cat(chunk("hi"), chunk("yo"), webTrailer("grpc-status: 0\r\n")) },
  },
  {
    name: "split one byte at a time",
    split: 1,
    reply: { status: 200, headers: WEB, body: cat(chunk("abc"), webTrailer("grpc-status:0\r\n")) },
  },
  {
    name: "mid-stream status error",
    reply: {
      status: 200,
      headers: WEB,
      body: cat(chunk("one"), webTrailer("grpc-status: 5\r\ngrpc-message: vm%20gone\r\n")),
    },
  },
  {
    name: "no status at the end",
    reply: { status: 200, headers: WEB, body: cat(chunk("one")) },
  },
  {
    name: "trailers-only error",
    reply: {
      status: 200,
      headers: { ...WEB, "grpc-status": "16", "grpc-message": "bad token" },
      body: Buffer.alloc(0),
    },
  },
  {
    name: "trailers-only OK",
    reply: { status: 200, headers: { ...WEB, "grpc-status": "0" }, body: Buffer.alloc(0) },
  },
  {
    name: "truncated frame after OK",
    reply: {
      status: 200,
      headers: WEB,
      body: cat(chunk("one"), webTrailer("grpc-status: 0\r\n"), Buffer.from([0, 0, 0, 0, 9, 1])),
    },
  },
  {
    name: "compressed frame",
    reply: { status: 200, headers: WEB, body: cat(frame(Buffer.from([1, 2]), 1)) },
  },
  {
    name: "HTTP 503 text",
    reply: { status: 503, headers: { "content-type": "text/plain" }, body: Buffer.from("down") },
  },
];

for (const c of boxdCases) {
  const sent = [];
  const input = { vmId: "vm-1", follow: true };
  const reply = {
    status: c.reply.status,
    headers: c.reply.headers,
    chunks: chunked(c.reply.body, c.split).map((x) => b64(x)),
  };
  const r = await drain(BOXD.svc.streamLogs.stream(input), boxdLayer(reply, sent));
  cases.push({ kind: "boxd", name: c.name, op: "stream_logs", input, reply, sent, ...r });
}

// --- e2b: Connect server streams ----------------------------------------------------

const CJ = { "content-type": "application/connect+json" };
const e2bCases = [
  {
    name: "start: events then end of stream",
    fn: "startProcess",
    input: { process: { args: ["-c", "echo hi"], cmd: "sh" } },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(
        envelope({ event: { start: { pid: 42 } } }),
        envelope({ event: { data: { stdout: b64(Buffer.from("hi\n")) } } }),
        envelope({ event: { data: { stderr: b64(Buffer.from("warn")) } } }),
        envelope({ event: { keepalive: {} } }),
        envelope({ event: { end: { exitCode: 1, exited: true, status: "exit status 1" } } }),
        envelope({}, 2),
      ),
    },
  },
  {
    name: "start: split in 3-byte chunks",
    fn: "startProcess",
    split: 3,
    input: { process: { cmd: "ls" } },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(envelope({ event: { start: { pid: 1 } } }), envelope({ event: { data: {} } }), envelope({}, 2)),
    },
  },
  {
    name: "start: end-of-stream error",
    fn: "startProcess",
    input: { process: { cmd: "nope" } },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(
        envelope({ event: { start: { pid: 3 } } }),
        envelope({ error: { code: "not_found", message: "no such file" } }, 2),
      ),
    },
  },
  {
    name: "start: unknown end-of-stream code",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(envelope({ error: { code: "resource_exhausted" } }, 2)),
    },
  },
  {
    name: "start: 502 before the stream",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: {
      status: 502,
      headers: { "content-type": "application/json" },
      body: Buffer.from('{"sandboxId":"sb-1","message":"The sandbox was not found","code":502}'),
    },
  },
  {
    name: "start: 404 without a code",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: { status: 404, headers: {}, body: Buffer.from("404 page not found") },
  },
  {
    name: "start: 400 with a Connect code",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: { status: 400, headers: {}, body: Buffer.from('{"code":"invalid_argument","message":"bad"}') },
  },
  {
    name: "start: 500 without a code",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: { status: 500, headers: {}, body: Buffer.from("oops") },
  },
  {
    name: "start: unknown event",
    fn: "startProcess",
    input: { process: { cmd: "x" } },
    reply: { status: 200, headers: CJ, body: cat(envelope({ event: { mystery: {} } })) },
  },
  {
    name: "connect: by tag",
    fn: "connectProcess",
    input: { process: { tag: "web" } },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(envelope({ event: { data: { pty: b64(Buffer.from([27, 91, 65])) } } }), envelope({}, 2)),
    },
  },
  {
    name: "watch: events",
    fn: "watchDir",
    input: { path: "/home/user", recursive: true },
    reply: {
      status: 200,
      headers: CJ,
      body: cat(
        envelope({ start: {} }),
        envelope({ filesystem: { name: "a.txt", type: "EVENT_TYPE_WRITE", entry: { name: "a.txt", size: 3 } } }),
        envelope({ filesystem: {} }),
        envelope({ keepalive: {} }),
        envelope({}, 2),
      ),
    },
  },
];

for (const c of e2bCases) {
  const sent = [];
  const reply = {
    status: c.reply.status,
    headers: c.reply.headers,
    chunks: chunked(c.reply.body, c.split).map((x) => b64(x)),
  };
  const layer = Layer.mergeAll(
    E2B.creds.sandboxConnection({ sandboxId: "sb-1", accessToken: Redacted.make("envd-tok") }),
    stub(reply, sent),
  );
  const r = await drain(E2B.connect[c.fn](c.input), layer);
  cases.push({ kind: "e2b", name: c.name, fn: c.fn, input: c.input, reply, sent, ...r });
}

writeFileSync(out, JSON.stringify({ cases }, null, 1) + "\n");
console.log(`wrote ${out}: ${cases.length} cases`);
