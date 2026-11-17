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
  `wrote ${out}: ${result.vectors.length} vectors, ${result.encode.length + result.encode_events.length} encodings, ${result.decode.length} decodings, ${result.signing.cases.length} signatures`,
);
