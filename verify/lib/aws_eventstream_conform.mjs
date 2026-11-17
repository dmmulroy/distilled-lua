// Writes spec/golden/aws_eventstream/conform.lua: what Distilled (packages/s3/src/eventstream,
// the AWS protocols) and the AWS SDK's signer do with event stream messages, for
// spec/aws_eventstream_spec.lua to replay on every runtime.
//
//   vectors    aws-sdk-go-v2's published codec vectors (spec/golden/aws_eventstream/
//              aws-sdk-go-v2, Apache-2.0): bytes and their decoded form, or the error
//   encode     messages encoded by Distilled's encodeMessage / encodeEvent (hex)
//   decode     bytes decoded by Distilled's decodeMessage + parseEvent: the message, or
//              Distilled's error message (corrupted CRCs, truncation, bad headers)
//   signing    signed envelopes from @smithy/signature-v4 signMessage, framed as the
//              SDK's EventSigningTransformStream frames them
//   outputs    Distilled clients over a stub HttpClient answering with event stream bytes:
//              the output members and the stream's events (or the error ending it)
//   inputs     the request Distilled builds for a bidirectional operation and the frames
//              of its input event stream
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/aws_eventstream_conform.mjs spec/golden/aws_eventstream/conform.lua
// DISTILLED_ROOT overrides ../distilled.
import * as path from "node:path";
import { createHash, createHmac } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const Codec = await import(path.join(P, "s3/src/eventstream/codec.ts"));
const Effect = await import(E + "Effect.js");

const out = process.argv[2];
if (!out) throw new Error("usage: aws_eventstream_conform.mjs <out.lua>");

const hex = (b) => Buffer.from(b).toString("hex");
const result = {};

// ---------------------------------------------------------------------------------------
// header views shared with the spec: { name, type (wire number), value }
// strings as text, byte arrays and uuids as hex, longs and timestamps as decimal text
// ---------------------------------------------------------------------------------------

const headerView = (name, h) => {
  switch (h.type) {
    case 0:
    case 1:
      return { name, type: h.type, value: h.value };
    case 2:
    case 3:
    case 4:
      return { name, type: h.type, value: h.value };
    case 5:
      return { name, type: h.type, value: String(h.value) };
    case 6:
    case 9:
      return { name, type: h.type, hex: hex(h.value) };
    case 7:
      return { name, type: h.type, value: h.value };
    case 8:
      return { name, type: h.type, value: String(h.value.getTime()) };
  }
  throw new Error("header type " + h.type);
};

// a spec header (as written in the cases below) -> a Distilled header value
const toDistilled = (h) => {
  switch (h.type) {
    case "boolean":
      return h.value ? { type: 0, value: true } : { type: 1, value: false };
    case "byte":
      return { type: 2, value: h.value };
    case "short":
      return { type: 3, value: h.value };
    case "integer":
      return { type: 4, value: h.value };
    case "long":
      return { type: 5, value: BigInt(h.value) };
    case "binary":
      return { type: 6, value: Buffer.from(h.hex, "hex") };
    case "string":
      return { type: 7, value: h.value };
    case "timestamp":
      return { type: 8, value: new Date(Number(h.value)) };
    case "uuid":
      return { type: 9, value: Buffer.from(h.hex, "hex") };
  }
  throw new Error("type " + h.type);
};
const headersOf = (list) => {
  const o = {};
  for (const h of list) o[h.name] = toDistilled(h);
  return o;
};

const run = (eff) => {
  const r = Effect.runSync(Effect.result(eff));
  return r._tag === "Success" ? { ok: true, value: r.success } : { ok: false, error: r.failure };
};

// ---------------------------------------------------------------------------------------
// aws-sdk-go-v2 vectors
// ---------------------------------------------------------------------------------------

const GO = path.join(ROOT, "spec/golden/aws_eventstream/aws-sdk-go-v2");
result.vectors = [];
for (const kind of ["positive", "negative"]) {
  for (const name of readdirSync(path.join(GO, "encoded", kind)).sort()) {
    const bytes = readFileSync(path.join(GO, "encoded", kind, name));
    const decoded = readFileSync(path.join(GO, "decoded", kind, name), "utf8");
    const entry = { id: kind + "/" + name, hex: hex(bytes) };
    if (kind === "positive") {
      const d = JSON.parse(decoded);
      entry.expected = {
        ok: true,
        total_length: d.total_length,
        headers_length: d.headers_length,
        prelude_crc: d.prelude_crc >>> 0,
        message_crc: d.message_crc >>> 0,
        payload_hex: hex(Buffer.from(d.payload ?? "", "base64")),
        headers: d.headers.map((h) => {
          if (h.type === 7) return { name: h.name, type: 7, value: Buffer.from(h.value, "base64").toString("utf8") };
          if (h.type === 6 || h.type === 9) return { name: h.name, type: h.type, hex: hex(Buffer.from(h.value, "base64")) };
          if (h.type === 5 || h.type === 8) return { name: h.name, type: h.type, value: String(h.value) };
          return { name: h.name, type: h.type, value: h.value };
        }),
      };
    } else {
      entry.expected = { ok: false, go_message: decoded.trim() };
    }
    // what Distilled says about the same bytes
    const r = run(Codec.decodeMessage(new Uint8Array(bytes)));
    entry.distilled = r.ok
      ? { ok: true, headers: Object.entries(r.value[0].headers).map(([n, h]) => headerView(n, h)) }
      : { ok: false, message: r.error.message };
    result.vectors.push(entry);
  }
}

// ---------------------------------------------------------------------------------------
// encoding
// ---------------------------------------------------------------------------------------

const ALL_TYPES = [
  { name: "t", type: "boolean", value: true },
  { name: "f", type: "boolean", value: false },
  { name: "byte", type: "byte", value: -128 },
  { name: "byte2", type: "byte", value: 127 },
  { name: "short", type: "short", value: -32768 },
  { name: "short2", type: "short", value: 12345 },
  { name: "int", type: "integer", value: -2147483648 },
  { name: "int2", type: "integer", value: 2147483647 },
  { name: "long", type: "long", value: "-9007199254740991" },
  { name: "long2", type: "long", value: "1234567890123" },
  { name: "long3", type: "long", value: "-1" },
  { name: "bin", type: "binary", hex: "00ff10" },
  { name: "empty-bin", type: "binary", hex: "" },
  { name: "str", type: "string", value: "héllo wörld ✓" },
  { name: "empty-str", type: "string", value: "" },
  { name: "ts", type: "timestamp", value: "1700000000000" },
  { name: "ts-neg", type: "timestamp", value: "-1000" },
  { name: "uuid", type: "uuid", hex: "0102030405060708090a0b0c0d0e0f10" },
];

const encodeCases = [
  { id: "empty", headers: [], payload_hex: "" },
  { id: "payload-only", headers: [], payload_hex: Buffer.from('{"foo":"bar"}').toString("hex") },
  { id: "all-types", headers: ALL_TYPES, payload_hex: "000102fffe" },
  {
    id: "event",
    headers: [
      { name: ":message-type", type: "string", value: "event" },
      { name: ":event-type", type: "string", value: "chunk" },
      { name: ":content-type", type: "string", value: "application/json" },
    ],
    payload_hex: Buffer.from('{"bytes":"aGk="}').toString("hex"),
  },
  { id: "binary-payload", headers: [{ name: "x", type: "string", value: "y" }], payload_hex: "00".repeat(300) + "ff".repeat(70000) },
  { id: "long-name", headers: [{ name: "n".repeat(255), type: "boolean", value: true }], payload_hex: "" },
  { id: "name-too-long", headers: [{ name: "n".repeat(256), type: "boolean", value: true }], payload_hex: "" },
  { id: "name-empty", headers: [{ name: "", type: "boolean", value: true }], payload_hex: "" },
];
result.encode = [];
for (const c of encodeCases) {
  const r = run(Codec.encodeMessage({ headers: headersOf(c.headers), payload: Buffer.from(c.payload_hex, "hex") }));
  // large payloads: keep the case small in the golden file (the spec rebuilds it)
  result.encode.push({
    id: c.id,
    headers: c.headers,
    payload_hex: c.payload_hex.length > 2000 ? undefined : c.payload_hex,
    payload_rep: c.id === "binary-payload" ? [["00", 300], ["ff", 70000]] : undefined,
    expected: r.ok
      ? { ok: true, hex: c.payload_hex.length > 2000 ? undefined : hex(r.value), sha256: createHash("sha256").update(r.value).digest("hex"), length: r.value.length }
      : { ok: false, message: r.error.message },
  });
}

// encodeEvent: the standard headers first, the event's own spread over them
const eventCases = [
  { id: "message-event", event: { _tag: "MessageEvent", eventType: "AudioEvent", contentType: "application/octet-stream", payload: "0102", headers: [] } },
  { id: "message-event-no-content-type", event: { _tag: "MessageEvent", eventType: "E", payload: "", headers: [{ name: "extra", type: "integer", value: 7 }] } },
  {
    id: "message-event-override",
    event: {
      _tag: "MessageEvent",
      eventType: "E",
      contentType: "text/plain",
      payload: "41",
      headers: [
        { name: ":content-type", type: "string", value: "x/y" },
        { name: ":event-type", type: "string", value: "Other" },
      ],
    },
  },
  { id: "exception-event", event: { _tag: "ExceptionEvent", exceptionType: "BadRequestException", contentType: "application/json", payload: Buffer.from('{"Message":"no"}').toString("hex"), headers: [] } },
  { id: "error-event", event: { _tag: "ErrorEvent", errorCode: "InternalFailure", errorMessage: "boom", headers: [] } },
];
result.encode_events = [];
for (const c of eventCases) {
  const ev = { ...c.event, headers: headersOf(c.event.headers), payload: Buffer.from(c.event.payload ?? "", "hex") };
  const r = run(Codec.encodeEvent(ev));
  result.encode_events.push({ id: c.id, event: c.event, expected: { ok: true, hex: hex(r.value) } });
}

// ---------------------------------------------------------------------------------------
// decoding (decodeMessage + parseEvent)
// ---------------------------------------------------------------------------------------

const enc = (headers, payloadHex = "") =>
  Buffer.from(run(Codec.encodeMessage({ headers: headersOf(headers), payload: Buffer.from(payloadHex, "hex") })).value);
const s = (name, value) => ({ name, type: "string", value });
const good = enc([s(":message-type", "event"), s(":event-type", "chunk")], "7b7d");
const flip = (b, at) => {
  const c = Buffer.from(b);
  c[at] ^= 0x01;
  return c;
};
// a message whose header block is given raw, with correct CRCs
const rawHeaders = (headerHex, payloadHex = "") => {
  const h = Buffer.from(headerHex, "hex");
  const p = Buffer.from(payloadHex, "hex");
  const total = 12 + h.length + p.length + 4;
  const b = Buffer.alloc(total);
  b.writeUInt32BE(total, 0);
  b.writeUInt32BE(h.length, 4);
  b.writeUInt32BE(crc32(b.subarray(0, 8)), 8);
  h.copy(b, 12);
  p.copy(b, 12 + h.length);
  b.writeUInt32BE(crc32(b.subarray(0, total - 4)), total - 4);
  return b;
};
// prelude fields given raw (with correct CRCs over whatever they say)
const rawPrelude = (total, headersLength, size) => {
  const b = Buffer.alloc(size);
  b.writeUInt32BE(total, 0);
  b.writeUInt32BE(headersLength, 4);
  b.writeUInt32BE(crc32(b.subarray(0, 8)), 8);
  if (size >= 16) b.writeUInt32BE(crc32(b.subarray(0, size - 4)), size - 4);
  return b;
};
function crc32(buf) {
  let c = ~0 >>> 0;
  for (const x of buf) {
    c ^= x;
    for (let k = 0; k < 8; k++) c = c & 1 ? (c >>> 1) ^ 0xedb88320 : c >>> 1;
  }
  return ~c >>> 0;
}
const name = (n) => Buffer.from([n.length, ...Buffer.from(n)]).toString("hex");

const decodeCases = [
  { id: "event", bytes: good },
  { id: "exception", bytes: enc([s(":message-type", "exception"), s(":exception-type", "ValidationException"), s(":content-type", "application/json")], Buffer.from('{"message":"bad"}').toString("hex")) },
  { id: "error", bytes: enc([s(":message-type", "error"), s(":error-code", "InternalError"), s(":error-message", "it broke")]) },
  { id: "all-types", bytes: enc(ALL_TYPES, "ff00") },
  { id: "too-short", bytes: good.subarray(0, 15) },
  { id: "incomplete", bytes: good.subarray(0, good.length - 1) },
  { id: "prelude-crc", bytes: flip(good, 9) },
  { id: "message-crc", bytes: flip(good, good.length - 1) },
  { id: "payload-flipped", bytes: flip(good, good.length - 6) },
  { id: "length-below-minimum", bytes: rawPrelude(15, 0, 16) },
  { id: "headers-length-too-big", bytes: rawPrelude(16, 1, 16) },
  { id: "unknown-header-type", bytes: rawHeaders(name("x") + "0a") },
  { id: "name-no-room", bytes: rawHeaders(name("abc")) },
  { id: "string-past-end", bytes: rawHeaders(name("x") + "070005414243") },
  { id: "int-past-end", bytes: rawHeaders(name("x") + "040001") },
  { id: "uuid-past-end", bytes: rawHeaders(name("x") + "09" + "00".repeat(15)) },
  { id: "missing-message-type", bytes: enc([s(":event-type", "chunk")]) },
  { id: "message-type-not-string", bytes: enc([{ name: ":message-type", type: "integer", value: 1 }]) },
  { id: "missing-event-type", bytes: enc([s(":message-type", "event")]) },
  { id: "missing-exception-type", bytes: enc([s(":message-type", "exception")]) },
  { id: "missing-error-code", bytes: enc([s(":message-type", "error"), s(":error-message", "m")]) },
  { id: "missing-error-message", bytes: enc([s(":message-type", "error"), s(":error-code", "C")]) },
  { id: "unknown-message-type", bytes: enc([s(":message-type", "ping")]) },
  { id: "repeated-header", bytes: rawHeaders(name(":message-type") + "070005" + Buffer.from("event").toString("hex") + name(":event-type") + "070001" + Buffer.from("a").toString("hex") + name(":event-type") + "070001" + Buffer.from("b").toString("hex")) },
];
result.decode = [];
for (const c of decodeCases) {
  const r = run(Codec.decodeMessage(new Uint8Array(c.bytes)));
  let expected;
  if (!r.ok) {
    expected = { ok: false, stage: "message", message: r.error.message };
  } else {
    const [m, consumed] = r.value;
    const message = {
      consumed,
      payload_hex: hex(m.payload),
      headers: Object.entries(m.headers).map(([n, h]) => headerView(n, h)),
    };
    const ev = run(Codec.parseEvent(m));
    if (!ev.ok) expected = { ok: false, stage: "event", message: ev.error.message, decoded: message };
    else {
      const e = ev.value;
      expected = {
        ok: true,
        message,
        event: {
          kind: { MessageEvent: "event", ExceptionEvent: "exception", ErrorEvent: "error" }[e._tag],
          event_type: e.eventType,
          exception_type: e.exceptionType,
          content_type: e.contentType,
          error_code: e.errorCode,
          error_message: e.errorMessage,
        },
      };
    }
  }
  result.decode.push({ id: c.id, hex: hex(c.bytes), expected });
}

// ---------------------------------------------------------------------------------------
// signing: @smithy/signature-v4 signMessage, framed as EventSigningTransformStream does
// ---------------------------------------------------------------------------------------

const SV4 = await import(
  path.join(DISTILLED, "node_modules/.pnpm/@smithy+signature-v4@5.7.4/node_modules/@smithy/signature-v4/dist-cjs/index.js")
);
class Sha256 {
  constructor(secret) {
    this.h = secret ? createHmac("sha256", Buffer.from(secret)) : createHash("sha256");
  }
  update(d) {
    this.h.update(typeof d === "string" ? Buffer.from(d) : Buffer.from(d));
  }
  async digest() {
    return new Uint8Array(this.h.digest());
  }
}
const AKID = "AKIAIOSFODNN7EXAMPLE";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const signer = new SV4.SignatureV4({
  credentials: { accessKeyId: AKID, secretAccessKey: SECRET },
  region: "us-west-2",
  service: "transcribe",
  sha256: Sha256,
  applyChecksum: false,
});
const signCases = [
  { id: "first", prior: "d6a2e1b8f3c7a9e5d4b2c1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0", epoch_ms: 1700000000000, payload_hex: hex(enc([s(":message-type", "event"), s(":event-type", "AudioEvent"), s(":content-type", "application/octet-stream")], "00010203")) },
  { id: "empty-end-frame", prior: "1111111111111111111111111111111111111111111111111111111111111111", epoch_ms: 1700000001000, payload_hex: "" },
  { id: "other-day", prior: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", epoch_ms: 1735689599000, payload_hex: "ffee" },
];
result.signing = { access_key_id: AKID, secret_access_key: SECRET, region: "us-west-2", service: "transcribe", cases: [] };
for (const c of signCases) {
  const date = new Date(c.epoch_ms);
  const dateHeader = { ":date": { type: "timestamp", value: date } };
  const payload = Buffer.from(c.payload_hex, "hex");
  const signed = await signer.signMessage(
    { message: { body: payload, headers: dateHeader }, priorSignature: c.prior },
    { signingDate: date },
  );
  // the envelope, with Distilled's encoder (the SDK's EventStreamCodec writes the same bytes)
  const frame = run(
    Codec.encodeMessage({
      headers: {
        ":date": { type: 8, value: date },
        ":chunk-signature": { type: 6, value: Buffer.from(signed.signature, "hex") },
      },
      payload,
    }),
  ).value;
  result.signing.cases.push({ id: c.id, prior: c.prior, epoch_ms: c.epoch_ms, payload_hex: c.payload_hex, expected: { signature: signed.signature, frame_hex: hex(frame) } });
}

// ---------------------------------------------------------------------------------------
// operations: Distilled's generated clients over a stub HttpClient
// ---------------------------------------------------------------------------------------

const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");
const Exit = await import(E + "Exit.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Stream = await import(E + "Stream.js");
const Credentials = await import(path.join(P, "s3/src/credentials.ts"));
const Retry = await import(path.join(P, "aws/src/retry.ts"));

const FIXED_MS = 1700000000 * 1000;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...args) {
    super(...(args.length === 0 ? [FIXED_MS] : args));
  }
  static now() {
    return FIXED_MS;
  }
};

// values as the spec compares them: bytes { $hex }, secrets { $redacted }, dates seconds
const view = (v) => {
  if (v === null || v === undefined) return v;
  if (v instanceof RealDate) return v.getTime() / 1000;
  if (v instanceof Uint8Array) return { $hex: hex(v) };
  if (Redacted.isRedacted(v)) return { $redacted: view(Redacted.value(v)) };
  if (Array.isArray(v)) return v.map(view);
  if (typeof v === "object") {
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      const p = view(x);
      if (p !== undefined) out[k] = p;
    }
    return out;
  }
  return v;
};
const errorView = (e) => {
  if (!e || typeof e !== "object") return { tag: String(e) };
  const fields = {};
  for (const [k, v] of Object.entries(e)) {
    if (k !== "stack" && k !== "_tag" && k !== "cause" && k !== "message") fields[k] = view(v);
  }
  return { tag: e._tag, message: e.message, fields };
};
// case input -> TS input: { $hex } becomes bytes
const toInput = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(toInput);
  const keys = Object.keys(v);
  if (keys.length === 1 && keys[0] === "$hex") return new Uint8Array(Buffer.from(v.$hex, "hex"));
  const o = {};
  for (const k of keys) o[k] = toInput(v[k]);
  return o;
};

const modules = {};
const service = async (name) =>
  (modules[name] ??= await import(
    name === "s3" ? path.join(P, "s3/src/services/s3.ts") : path.join(P, "aws/src/services", `${name}.ts`)
  ));
const lowerFirst = (x) => x.charAt(0).toLowerCase() + x.slice(1);
const creds = Layer.succeed(
  Credentials.Credentials,
  Effect.succeed({
    accessKeyId: Redacted.make(AKID),
    secretAccessKey: Redacted.make(SECRET),
    sessionToken: undefined,
    region: "us-east-1",
  }),
);

// a message from a compact description: [type, eventType | exceptionType | [code, message], payload text | {hex}, extra headers]
const message = (m) => {
  const [kind, name, payload, extra] = m;
  const headers = [s(":message-type", kind)];
  if (kind === "event") headers.push(s(":event-type", name));
  if (kind === "exception") headers.push(s(":exception-type", name));
  if (kind === "error") headers.push(s(":error-code", name[0]), s(":error-message", name[1]));
  if (kind !== "error") headers.push(s(":content-type", typeof payload === "object" ? "application/octet-stream" : "application/json"));
  for (const h of extra ?? []) headers.push(h);
  const p = payload === undefined ? "" : typeof payload === "object" ? payload.hex : Buffer.from(payload).toString("hex");
  return enc(headers, p);
};
const xml = (kind, name, payload) => {
  const headers = [s(":message-type", kind), s(":event-type", name), s(":content-type", "text/xml")];
  return enc(headers, Buffer.from(payload).toString("hex"));
};

const outputCases = [
  {
    id: "bedrock-invoke-chunks",
    service: "bedrock-runtime",
    op: "InvokeModelWithResponseStream",
    input: { modelId: "anthropic.claude", body: { $hex: Buffer.from('{"prompt":"hi"}').toString("hex") } },
    headers: { "x-amzn-bedrock-content-type": "application/json", "x-amzn-bedrock-performanceconfig-latency": "standard" },
    messages: [
      ["event", "chunk", '{"bytes":"eyJ0eXBlIjoiY29udGVudCJ9"}'],
      ["event", "chunk", '{"bytes":"eyJ0eXBlIjoic3RvcCJ9"}'],
    ],
  },
  {
    id: "bedrock-invoke-exception",
    service: "bedrock-runtime",
    op: "InvokeModelWithResponseStream",
    input: { modelId: "m", body: { $hex: "7b7d" } },
    headers: { "x-amzn-bedrock-content-type": "application/json" },
    messages: [
      ["event", "chunk", '{"bytes":"aGk="}'],
      ["exception", "modelStreamErrorException", '{"message":"model failed","originalStatusCode":500,"originalMessage":"oops"}'],
    ],
  },
  {
    id: "bedrock-converse-stream",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [{ role: "user", content: [{ text: "hello" }] }] },
    messages: [
      ["event", "messageStart", '{"role":"assistant"}'],
      ["event", "contentBlockDelta", '{"contentBlockIndex":0,"delta":{"text":"Hel"}}'],
      ["event", "contentBlockDelta", '{"contentBlockIndex":0,"delta":{"text":"lo"}}'],
      ["event", "contentBlockStop", '{"contentBlockIndex":0}'],
      ["event", "messageStop", '{"stopReason":"end_turn"}'],
      ["event", "metadata", '{"usage":{"inputTokens":3,"outputTokens":2,"totalTokens":5},"metrics":{"latencyMs":120}}'],
    ],
  },
  {
    id: "bedrock-converse-unknown-event",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    messages: [
      ["event", "brandNewEvent", '{"x":1}'],
      ["event", "messageStop", '{"stopReason":"end_turn"}'],
    ],
  },
  {
    id: "bedrock-converse-unmodeled-error",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    messages: [
      ["event", "messageStart", '{"role":"assistant"}'],
      ["error", ["ThrottlingException", "slow down"]],
    ],
  },
  {
    id: "bedrock-converse-truncated",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    messages: [["event", "messageStart", '{"role":"assistant"}']],
    truncate: 5,
  },
  {
    id: "bedrock-converse-bad-crc",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    messages: [
      ["event", "messageStart", '{"role":"assistant"}'],
      ["event", "messageStop", '{"stopReason":"end_turn"}'],
    ],
    corrupt_last: true,
  },
  {
    id: "bedrock-converse-http-error",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    status: 400,
    headers: { "x-amzn-errortype": "ValidationException:http://internal.amazon.com/coral/" },
    raw_body: '{"message":"bad model"}',
  },
  {
    id: "bedrock-converse-empty",
    service: "bedrock-runtime",
    op: "ConverseStream",
    input: { modelId: "m", messages: [] },
    messages: [],
  },
  {
    id: "kinesis-subscribe",
    service: "kinesis",
    op: "SubscribeToShard",
    input: { ConsumerARN: "arn:aws:kinesis:us-east-1:123456789012:stream/s/consumer/c:1", ShardId: "shardId-000000000000", StartingPosition: { Type: "LATEST" } },
    messages: [
      ["event", "initial-response", "{}"],
      [
        "event",
        "SubscribeToShardEvent",
        '{"Records":[{"SequenceNumber":"1","ApproximateArrivalTimestamp":1700000000.5,"Data":"aGVsbG8=","PartitionKey":"pk"}],"ContinuationSequenceNumber":"2","MillisBehindLatest":0}',
      ],
    ],
  },
  {
    id: "kinesis-exception",
    service: "kinesis",
    op: "SubscribeToShard",
    input: { ConsumerARN: "arn:aws:kinesis:us-east-1:123456789012:stream/s/consumer/c:1", ShardId: "s", StartingPosition: { Type: "LATEST" } },
    messages: [["exception", "ResourceInUseException", '{"message":"in use"}']],
  },
  {
    id: "lambda-invoke-stream",
    service: "lambda",
    op: "InvokeWithResponseStream",
    input: { FunctionName: "fn", Payload: { $hex: "7b7d" } },
    headers: { "x-amz-executed-version": "$LATEST", "content-type": "application/vnd.amazon.eventstream" },
    status: 200,
    messages: [
      ["event", "PayloadChunk", { hex: Buffer.from("part one ").toString("hex") }],
      ["event", "PayloadChunk", { hex: "00ff10" }],
      ["event", "InvokeComplete", '{"LogResult":"bG9n"}'],
    ],
  },
  {
    id: "s3-select",
    service: "s3",
    op: "SelectObjectContent",
    input: {
      Bucket: "b",
      Key: "k.csv",
      Expression: "select * from S3Object",
      ExpressionType: "SQL",
      InputSerialization: { CSV: {} },
      OutputSerialization: { CSV: {} },
    },
    raw_messages: () => [
      enc([s(":message-type", "event"), s(":event-type", "Records"), s(":content-type", "application/octet-stream")], Buffer.from("a,b\n1,2\n").toString("hex")),
      xml("event", "Stats", "<Stats><BytesScanned>100</BytesScanned><BytesProcessed>90</BytesProcessed><BytesReturned>8</BytesReturned></Stats>"),
      enc([s(":message-type", "event"), s(":event-type", "End")], ""),
    ],
  },
];

result.outputs = [];
for (const c of outputCases) {
  const mod = await service(c.service);
  const fn = mod[lowerFirst(c.op)];
  let bytes;
  if (c.raw_body !== undefined) bytes = Buffer.from(c.raw_body);
  else {
    const msgs = c.raw_messages ? c.raw_messages() : c.messages.map(message);
    if (c.corrupt_last) msgs[msgs.length - 1] = flip(msgs[msgs.length - 1], msgs[msgs.length - 1].length - 2);
    bytes = Buffer.concat(msgs);
    if (c.truncate) bytes = Buffer.concat([bytes, Buffer.alloc(c.truncate, 7)]);
  }
  const status = c.status ?? 200;
  const headers = { "content-type": "application/vnd.amazon.eventstream", ...(c.headers ?? {}) };
  let sent;
  const client = HttpClient.make((request) =>
    Effect.sync(() => {
      sent = request;
      return HttpClientResponse.fromWeb(request, new Response(bytes.length ? bytes : null, { status, headers }));
    }),
  );
  const events = [];
  let streamError;
  const exit = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const out = yield* fn(toInput(c.input));
      const member = Object.keys(out).find((k) => Stream.isStream(out[k]));
      const rest = {};
      for (const [k, v] of Object.entries(out)) if (k !== member) rest[k] = v;
      if (member) {
        const r = yield* Effect.result(Stream.runForEach(out[member], (e) => Effect.sync(() => events.push(view(e)))));
        if (r._tag === "Failure") streamError = errorView(r.failure);
      }
      return { member, output: view(rest) };
    }).pipe(Retry.none, Effect.provide(Layer.mergeAll(creds, Layer.succeed(HttpClient.HttpClient, client)))),
  );
  const entry = { id: c.id, service: c.service, op: c.op, input: c.input, response: { status, headers, body_hex: hex(bytes) } };
  if (sent) entry.request = { method: sent.method, url: sent.url };
  if (Exit.isSuccess(exit)) {
    entry.expected = { ok: true, member: exit.value.member, output: exit.value.output, events, error: streamError };
  } else {
    const reason = exit.cause.reasons.find((r) => r._tag === "Fail");
    entry.expected = { ok: false, error: reason ? errorView(reason.error) : { defect: String(exit.cause) } };
  }
  result.outputs.push(entry);
}

// inputs: the request and the input event frames of bidirectional operations
const inputCases = [
  {
    id: "transcribe-audio",
    service: "transcribe-streaming",
    op: "StartStreamTranscription",
    input: { LanguageCode: "en-US", MediaSampleRateHertz: 16000, MediaEncoding: "pcm" },
    member: "AudioStream",
    events: [{ AudioEvent: { AudioChunk: { $hex: "0001020304ff" } } }, { AudioEvent: { AudioChunk: { $hex: "" } } }],
    messages: [["event", "TranscriptEvent", '{"Transcript":{"Results":[{"ResultId":"r1","StartTime":0.5,"EndTime":1.25,"IsPartial":true,"Alternatives":[{"Transcript":"hello"}]}]}}']],
    headers: { "x-amzn-request-id": "req-1", "x-amzn-transcribe-language-code": "en-US", "x-amzn-transcribe-sample-rate": "16000", "x-amzn-transcribe-media-encoding": "pcm" },
  },
  {
    id: "transcribe-configuration",
    service: "transcribe-streaming",
    op: "StartStreamTranscription",
    input: { LanguageCode: "en-US", MediaSampleRateHertz: 8000, MediaEncoding: "ogg-opus", ShowSpeakerLabel: true },
    member: "AudioStream",
    events: [
      { ConfigurationEvent: { ChannelDefinitions: [{ ChannelId: 0, ParticipantRole: "AGENT" }], PostCallAnalyticsSettings: { OutputLocation: "s3://b/k", DataAccessRoleArn: "arn:aws:iam::1:role/r" } } },
      { AudioEvent: { AudioChunk: { $hex: "ffee" } } },
    ],
    messages: [],
  },
  {
    id: "lex-conversation",
    service: "lex-runtime-v2",
    op: "StartConversation",
    input: { botId: "BOT1", botAliasId: "ALIAS", localeId: "en_US", sessionId: "s-1", conversationMode: "TEXT" },
    member: "requestEventStream",
    events: [
      { ConfigurationEvent: { responseContentType: "text/plain; charset=utf-8", requestAttributes: { a: "1" }, eventId: "e1", clientTimestampMillis: 1700000000000 } },
      { TextInputEvent: { text: "book a hotel", eventId: "e2" } },
      { DisconnectionEvent: { eventId: "e3" } },
    ],
    messages: [["event", "HeartbeatEvent", '{"eventId":"h1"}']],
  },
  {
    id: "sagemaker-bidirectional",
    service: "sagemaker-runtime-http2",
    op: "InvokeEndpointWithBidirectionalStream",
    input: { EndpointName: "ep", TargetVariant: "v1" },
    member: "Body",
    events: [{ PayloadPart: { Bytes: { $hex: Buffer.from("chunk-1").toString("hex") }, DataType: "UTF8", CompletionState: "PARTIAL", P: "pad" } }],
    raw_messages: () => [
      enc(
        [s(":message-type", "event"), s(":event-type", "PayloadPart"), s(":content-type", "application/octet-stream"), s("DataType", "UTF8"), s("CompletionState", "COMPLETE")],
        Buffer.from("answer").toString("hex"),
      ),
    ],
    headers: { "x-amzn-invoked-production-variant": "v1" },
  },
];

result.inputs = [];
for (const c of inputCases) {
  const mod = await service(c.service);
  const fn = mod[lowerFirst(c.op)];
  const msgs = c.raw_messages ? c.raw_messages() : c.messages.map(message);
  const bytes = Buffer.concat(msgs);
  let sent;
  let frames = [];
  const client = HttpClient.make((request) =>
    Effect.gen(function* () {
      sent = request;
      if (request.body._tag === "Stream") {
        const chunks = yield* Stream.runCollect(request.body.stream);
        const all = Buffer.concat(Array.from(chunks).map((x) => Buffer.from(x)));
        let at = 0;
        while (at < all.length) {
          const n = all.readUInt32BE(at);
          frames.push(hex(all.subarray(at, at + n)));
          at += n;
        }
      }
      return HttpClientResponse.fromWeb(
        request,
        new Response(bytes.length ? bytes : null, { status: 200, headers: { "content-type": "application/vnd.amazon.eventstream", ...(c.headers ?? {}) } }),
      );
    }),
  );
  const events = [];
  let streamError;
  const input = { ...toInput(c.input), [c.member]: Stream.fromIterable(c.events.map(toInput)) };
  const exit = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const out = yield* fn(input);
      const member = Object.keys(out).find((k) => Stream.isStream(out[k]));
      const rest = {};
      for (const [k, v] of Object.entries(out)) if (k !== member) rest[k] = v;
      if (member) {
        const r = yield* Effect.result(Stream.runForEach(out[member], (e) => Effect.sync(() => events.push(view(e)))));
        if (r._tag === "Failure") streamError = errorView(r.failure);
      }
      return { member, output: view(rest) };
    }).pipe(Retry.none, Effect.provide(Layer.mergeAll(creds, Layer.succeed(HttpClient.HttpClient, client)))),
  );
  const headers = {};
  for (const [k, v] of Object.entries(sent?.headers ?? {})) headers[k.toLowerCase()] = typeof v === "string" ? v : Redacted.value(v);
  const entry = {
    id: c.id,
    service: c.service,
    op: c.op,
    input: c.input,
    member: c.member,
    events: c.events,
    response: { status: 200, headers: { "content-type": "application/vnd.amazon.eventstream", ...(c.headers ?? {}) }, body_hex: hex(bytes) },
    request: sent ? { method: sent.method, url: sent.url, headers } : undefined,
    frames,
  };
  if (Exit.isSuccess(exit)) {
    entry.expected = { ok: true, member: exit.value.member, output: exit.value.output, events, error: streamError };
  } else {
    const reason = exit.cause.reasons.find((r) => r._tag === "Fail");
    entry.expected = { ok: false, error: reason ? errorView(reason.error) : { defect: String(exit.cause) } };
  }
  result.inputs.push(entry);
}

// ---------------------------------------------------------------------------------------
// writing
// ---------------------------------------------------------------------------------------

const lua = (v, indent = "") => {
  if (v === undefined || v === null) return "nil";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") {
    let s = '"';
    for (const b of Buffer.from(v, "utf8")) {
      if (b === 0x22) s += '\\"';
      else if (b === 0x5c) s += "\\\\";
      else if (b >= 0x20 && b < 0x7f) s += String.fromCharCode(b);
      else s += "\\" + String(b).padStart(3, "0");
    }
    return s + '"';
  }
  const inner = indent + "  ";
  if (Array.isArray(v)) {
    if (!v.length) return "{ n = 0 }";
    return `{\n${v.map((x) => `${inner}${lua(x, inner)},`).join("\n")}\n${indent}}`;
  }
  const keys = Object.keys(v).sort();
  const parts = keys.filter((k) => v[k] !== undefined).map((k) => `${inner}[${lua(k)}] = ${lua(v[k], inner)},`);
  return parts.length ? `{\n${parts.join("\n")}\n${indent}}` : "{}";
};

writeFileSync(
  out,
  "-- Generated by verify/lib/aws_eventstream_conform.mjs from Distilled's packages/s3/src/eventstream,\n" +
    "-- its AWS protocols and @smithy/signature-v4. Do not edit. Bytes are hex.\nreturn " +
    lua(result) +
    "\n",
);
console.log(
  `wrote ${out}: ${result.vectors.length} vectors, ${result.encode.length + result.encode_events.length} encodings, ${result.decode.length} decodings, ${result.signing.cases.length} signatures, ${result.outputs.length} output streams, ${result.inputs.length} input streams`,
);
