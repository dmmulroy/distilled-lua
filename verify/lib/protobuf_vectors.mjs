// Protobuf differential vectors (task 23): runs Distilled's core protobuf.ts over a fixed
// descriptor set and seeded random values, and writes what it produced to
// spec/golden/protobuf/vectors.json. spec/protobuf_spec.lua replays them in every runtime:
// Lua must produce the same bytes (encode), the same value (decode) and the same error
// message for every case.
//
//   node --conditions=bun --experimental-transform-types verify/lib/protobuf_vectors.mjs [count]
//
// Values use keys in the order distilled.protobuf writes them (JavaScript's own order for
// a JSON object: array-index keys ascending, then the others, which are sorted here), so
// encoded bytes are comparable byte for byte, maps and Struct included.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const distilled = process.env.DL_DISTILLED ?? path.resolve(root, "..", "distilled");
const pb = await import(path.join(distilled, "packages/core/src/protobuf.ts"));

const COUNT = Number(process.argv[2] ?? 150);

// Park-Miller, as distilled.testing.random
const SEED = Number(process.env.DL_PB_SEED ?? 23);
let seed = SEED;
const rnd = () => {
  seed = (seed * 16807) % 2147483647;
  return (seed - 1) / 2147483646;
};
const int = (n) => Math.floor(rnd() * n);
const pick = (list) => list[int(list.length)];
const chance = (p) => rnd() < p;

const d = {
  messages: {
    "t.All": [
      [1, "dbl", "double"],
      [2, "flt", "float"],
      [3, "i32", "int32"],
      [4, "i64", "int64"],
      [5, "u32", "uint32"],
      [6, "u64", "uint64"],
      [7, "s32", "sint32"],
      [8, "s64", "sint64"],
      [9, "f32", "fixed32"],
      [10, "f64", "fixed64"],
      [11, "sf32", "sfixed32"],
      [12, "sf64", "sfixed64"],
      [13, "b", "bool"],
      [14, "s", "string"],
      [15, "by", "bytes"],
      [16, "color", "enum", "t.Color"],
      [17, "inner", "message", "t.Inner"],
      [18, "rI32", "int32", 0, 1],
      [19, "rStr", "string", 0, 1],
      [20, "rInner", "message", "t.Inner", 1],
      [21, "rColor", "enum", "t.Color", 1],
      [22, "rDbl", "double", 0, 1],
      [23, "rU64", "uint64", 0, 1],
      [24, "rBool", "bool", 0, 1],
      [25, "rS64", "sint64", 0, 1],
      [26, "rF32", "float", 0, 1],
      [27, "rBytes", "bytes", 0, 1],
      [30, "mStrStr", "map", ["string", "string"]],
      [31, "mI32Inner", "map", ["int32", "message", "t.Inner"]],
      [32, "mI64Color", "map", ["int64", "enum", "t.Color"]],
      [33, "mBoolDbl", "map", ["bool", "double"]],
      [34, "mU64Bytes", "map", ["uint64", "bytes"]],
      [35, "mStrI64", "map", ["string", "int64"]],
      [40, "optI32", "int32", 0, 0, 1],
      [41, "optStr", "string", 0, 0, 1],
      [42, "optColor", "enum", "t.Color", 0, 1],
      [50, "oneStr", "string", 0, 0, 2],
      [51, "oneInner", "message", "t.Inner", 0, 2],
      [52, "oneI64", "int64", 0, 0, 2],
      [60, "ts", "message", "google.protobuf.Timestamp"],
      [61, "dur", "message", "google.protobuf.Duration"],
      [62, "st", "message", "google.protobuf.Struct"],
      [63, "val", "message", "google.protobuf.Value"],
      [64, "lv", "message", "google.protobuf.ListValue"],
      [65, "fm", "message", "google.protobuf.FieldMask"],
      [66, "any", "message", "google.protobuf.Any"],
      [67, "wStr", "message", "google.protobuf.StringValue"],
      [68, "wI64", "message", "google.protobuf.Int64Value"],
      [69, "wBool", "message", "google.protobuf.BoolValue"],
      [70, "wDbl", "message", "google.protobuf.DoubleValue"],
      [71, "wU32", "message", "google.protobuf.UInt32Value"],
      [72, "wBytes", "message", "google.protobuf.BytesValue"],
      [73, "empty", "message", "google.protobuf.Empty"],
      [74, "rTs", "message", "google.protobuf.Timestamp", 1],
      [75, "rVal", "message", "google.protobuf.Value", 1],
      [76, "wFlt", "message", "google.protobuf.FloatValue"],
      [77, "wI32", "message", "google.protobuf.Int32Value"],
      [78, "wU64", "message", "google.protobuf.UInt64Value"],
      [536870911, "maxField", "int32"],
    ],
    "t.Inner": [
      [1, "name", "string"],
      [2, "n", "int32"],
      [3, "child", "message", "t.Inner"],
      [4, "tags", "string", 0, 1],
    ],
  },
  enums: {
    "t.Color": { COLOR_UNSPECIFIED: 0, RED: 1, BLUE: 2, NEG: -1 },
  },
  methods: {
    "/t.Svc/Get": ["t.Inner", "t.All"],
    "/t.Svc/Stream": ["t.Inner", "t.Inner", 1],
  },
};

const bytesKey = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const isIndex = (k) => /^(0|[1-9]\d*)$/.test(k) && Number(k) < 2 ** 32 - 1;
// an object whose keys are in distilled.protobuf's order (JS's for index keys)
const ordered = (entries) => {
  const idx = entries.filter(([k]) => isIndex(k)).sort((a, b) => Number(a[0]) - Number(b[0]));
  const other = entries.filter(([k]) => !isIndex(k)).sort((a, b) => bytesKey(a[0], b[0]));
  const out = {};
  for (const [k, v] of [...idx, ...other]) out[k] = v;
  return out;
};

const STRINGS = ["", "a", "hello", "héllo wörld", "日本語", "emoji 😀", "tab\tnew\nline", "q\"b\\", "0", "x".repeat(130)];
const big = (s) => s;
const INT64S = ["0", "1", "-1", "9223372036854775807", "-9223372036854775808", "4294967296", "-4294967297", "9007199254740993", "123456789012345678", "1e5", "-2.0e3", "007"];
const UINT64S = ["0", "1", "18446744073709551615", "4294967295", "9007199254740993", "1e3", "12345678901234567890"];
const DOUBLES = [0, -0, 1, -1, 0.1, 1.5, 1e308, -1e-308, 5e-324, 2.2250738585072014e-308, 123456.789, Math.PI, 2 ** 53, "NaN", "Infinity", "-Infinity", "1.25", "-3e2", 1e21, 1e-7];
const FLOATS = [0, -0, 1, 0.1, 3.4028234663852886e38, -3.4028234663852886e38, 1.1754943508222875e-38, 1.401298464324817e-45, 7e-46, 3.4e38, 16777217, 0.30000001192092896, 1e-40, "NaN", "Infinity", 2.5, 1.0000000596046448];
const B64 = ["", "AA==", "AQID", "//79", "-_-_", "aGVsbG8", "aGVsbG8=", "AAECAwQFBgcICQ==", "SGk gdGhlcmU="];

const genInt32 = () => pick([0, 1, -1, 2147483647, -2147483648, int(1000) - 500, 300, -300, "42", "-7", "1e2"]);
const genUint32 = () => pick([0, 1, 4294967295, int(100000), 2147483648, "77"]);
const genScalar = (kind) => {
  switch (kind) {
    case "double": return pick(DOUBLES);
    case "float": return pick(FLOATS);
    case "int32": case "sint32": case "sfixed32": return genInt32();
    case "uint32": case "fixed32": return genUint32();
    case "int64": case "sint64": case "sfixed64": return pick(INT64S);
    case "uint64": case "fixed64": return pick(UINT64S);
    case "bool": return chance(0.5);
    case "string": return pick(STRINGS);
    case "bytes": return pick(B64);
    case "enum": return pick(["COLOR_UNSPECIFIED", "RED", "BLUE", "NEG", 1, 7, -1]);
  }
  throw new Error(kind);
};

const genInner = (depth = 0) => {
  const o = [];
  if (chance(0.7)) o.push(["name", pick(STRINGS)]);
  if (chance(0.5)) o.push(["n", genInt32()]);
  if (depth < 4 && chance(0.3)) o.push(["child", genInner(depth + 1)]);
  if (chance(0.3)) o.push(["tags", Array.from({ length: int(3) }, () => pick(STRINGS))]);
  return ordered(o);
};

const pad = (n, w) => String(n).padStart(w, "0");
const genTimestamp = () => {
  const y = 1 + int(9999);
  const mo = 1 + int(12);
  const dd = 1 + int(28);
  const frac = pick(["", ".5", ".123", ".123456", ".123456789", ".000000001", ".100"]);
  const off = pick(["Z", "Z", "+01:00", "-05:30", "+00:00"]);
  const s = `${pad(y, 4)}-${pad(mo, 2)}-${pad(dd, 2)}T${pad(int(24), 2)}:${pad(int(60), 2)}:${pad(int(60), 2)}${frac}${off}`;
  return pick([s, s, "1970-01-01T00:00:00Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z", "2024-02-29T12:00:00Z", "1969-12-31T23:59:59.5Z"]);
};
const genDuration = () => pick(["0s", "1s", "-1.5s", "1.000000001s", "315576000000s", "-315576000000s", "0.25s", "-0.5s", 1.5, -2.25, 3, 0.000001, "12.500s"]);
const genJson = (depth = 0) => {
  const r = int(depth > 2 ? 4 : 6);
  switch (r) {
    case 0: return null;
    case 1: return pick([0, 1.5, -3, 1e300, 2 ** 53 + 2]);
    case 2: return pick(STRINGS);
    case 3: return chance(0.5);
    case 4: return Array.from({ length: int(4) }, () => genJson(depth + 1));
    default: {
      const keys = new Set();
      for (let i = int(4); i > 0; i--) keys.add(pick(["a", "b", "key", "0", "10", "2", "z_z", "é", "4294967295"]));
      return ordered([...keys].map((k) => [k, genJson(depth + 1)]));
    }
  }
};
const genAny = () => pick([
  ordered([["@type", "type.googleapis.com/t.Inner"], ...Object.entries(genInner())]),
  { "@type": "type.googleapis.com/google.protobuf.Timestamp", value: genTimestamp() },
  { "@type": "type.googleapis.com/google.protobuf.Duration", value: "1.5s" },
  { "@type": "type.example.com/x.Unknown", value: pick(B64) },
  { "@type": "type.googleapis.com/google.protobuf.Empty" },
  {},
  { "@type": "type.googleapis.com/google.protobuf.Struct", value: { k: genJson(2) } },
]);

const genField = ([, json, kind, ref, repeated]) => {
  if (kind === "map") {
    const [kk, vk, vr] = ref;
    const keys = new Set();
    for (let i = int(4); i > 0; i--) {
      const k = kk === "bool" ? String(chance(0.5)) : kk === "string" ? pick(STRINGS.slice(0, 7)) : String(kk === "uint64" ? pick(["0", "5", "18446744073709551615", "10"]) : pick(["0", "-1", "5", "10", "2147483647", "-9223372036854775808"]));
      keys.add(k);
    }
    return ordered([...keys].map((k) => [k, vk === "message" ? genInner() : genScalar(vk)]));
  }
  const one = () => {
    if (kind !== "message") return genScalar(kind);
    switch (ref) {
      case "t.Inner": return genInner();
      case "google.protobuf.Timestamp": return genTimestamp();
      case "google.protobuf.Duration": return genDuration();
      case "google.protobuf.Struct": {
        // a Struct is an object (protobuf.ts spreads a string into per-character entries)
        const v = genJson(1);
        return v !== null && typeof v === "object" ? v : { k: v };
      }
      case "google.protobuf.Value": return genJson();
      case "google.protobuf.ListValue": return Array.from({ length: int(3) }, () => genJson(2));
      case "google.protobuf.FieldMask": return pick(["", "a", "fooBar.baz", "a,bC,dEf.gH"]);
      case "google.protobuf.Any": return genAny();
      case "google.protobuf.StringValue": return pick(STRINGS);
      case "google.protobuf.Int64Value": return pick(INT64S);
      case "google.protobuf.UInt64Value": return pick(UINT64S);
      case "google.protobuf.Int32Value": return genInt32();
      case "google.protobuf.BoolValue": return chance(0.5);
      case "google.protobuf.DoubleValue": return pick(DOUBLES);
      case "google.protobuf.FloatValue": return pick(FLOATS);
      case "google.protobuf.UInt32Value": return genUint32();
      case "google.protobuf.BytesValue": return pick(B64);
      case "google.protobuf.Empty": return {};
    }
    throw new Error(ref);
  };
  return repeated ? Array.from({ length: int(4) }, one) : one();
};

const genAll = () => {
  const entries = [];
  let oneofUsed = false;
  for (const f of d.messages["t.All"]) {
    if (!chance(0.35)) continue;
    if (f[5] >= 2) {
      if (oneofUsed && !chance(0.1)) continue;
      oneofUsed = true;
    }
    entries.push([f[1], genField(f)]);
  }
  return ordered(entries);
};

// invalid values: each fails to encode
const BAD = [
  { i32: 2147483648 }, { i32: "2147483648" }, { i32: 1.5 }, { i32: "abc" }, { i32: true },
  { u32: -1 }, { u64: "-1" }, { u64: "18446744073709551616" }, { i64: "9223372036854775808" },
  { i64: "-9223372036854775809" }, { s64: 1e20 }, { s32: "1.5" }, { f32: 4294967296 },
  { flt: 3.5e38 }, { flt: "1e39" }, { dbl: "1e400" }, { dbl: "abc" }, { dbl: true },
  { b: "true" }, { b: 1 }, { s: 5 }, { color: "PURPLE" }, { color: 2147483648 },
  { rI32: 5 }, { rI32: [1, "x"] }, { inner: 5 }, { inner: { n: "q" } },
  { oneStr: "a", oneI64: "5" }, { ts: "2024-13-01T00:00:00Z" }, { ts: "2024-02-30T00:00:00Z" },
  { ts: "2024-01-01 00:00:00Z" }, { ts: "0000-12-31T23:59:59Z" }, { ts: "2024-01-01T24:00:00Z" },
  { ts: 5 }, { dur: "1.5" }, { dur: "315576000001s" }, { dur: "1.1234567891s" }, { fm: "a_b" },
  { fm: 5 }, { fm: "a-b" }, { any: 5 }, { any: [1] }, { any: { "@type": "nourl" } },
  { any: { "@type": "x/y.Unknown" } }, { any: { "@type": "x/google.protobuf.Timestamp", value: null } },
  { any: { "@type": "x/t.Inner", n: "bad" } }, { wI64: "x" }, { mStrStr: { a: 5 } },
  { mI32Inner: { "x": {} } }, { mBoolDbl: { "true": "zz" } }, { rInner: [{ child: { n: 1.5 } }] },
  { optI32: "1.5" }, { inner: { child: { child: { tags: [1] } } } },
];

const hex = (u8) => Buffer.from(u8).toString("hex");
const canon = (v) => JSON.stringify(v);

const encodeCases = [];
const add = (msg, original) => {
  // what Lua reads back from the text (JSON loses -0, for one)
  const text = JSON.stringify(original);
  const value = JSON.parse(text);
  try {
    const bytes = pb.encodeMessage(d, msg, value);
    const back = pb.decodeMessage(d, msg, bytes);
    encodeCases.push({ msg, value: text, hex: hex(bytes), decoded: canon(back) });
  } catch (e) {
    encodeCases.push({ msg, value: text, error: e.message, error_tag: e._tag ?? e.name });
  }
};
for (let i = 0; i < COUNT; i++) add("t.All", genAll());
for (const v of BAD) add("t.All", v);
// roots and special values
add("t.Inner", {});
add("t.Inner", null);
add("google.protobuf.Value", null);
add("google.protobuf.Timestamp", "2024-05-06T07:08:09.123Z");
add("google.protobuf.Struct", { a: [1, { b: null }], c: "x" });
add("google.protobuf.Empty", 5);
add("t.Nope", {});
add("t.All", { dbl: 0, flt: -0, i64: "0", s: "", b: false, color: "COLOR_UNSPECIFIED", optI32: 0, optStr: "", optColor: 0, oneStr: "" });
add("t.All", { s: "bad \ud800 surrogate" });

// decode vectors: valid encodings, mutated, plus hand-written byte strings
const decodeCases = [];
const addDecode = (msg, bytes) => {
  try {
    const v = pb.decodeMessage(d, msg, bytes);
    decodeCases.push({ msg, hex: hex(bytes), json: canon(v) });
  } catch (e) {
    decodeCases.push({ msg, hex: hex(bytes), error: e.message, error_tag: e._tag ?? e.name });
  }
};
const valid = encodeCases.filter((c) => c.hex !== undefined && c.msg === "t.All");
for (let i = 0; i < COUNT; i++) {
  const base = Buffer.from(pick(valid).hex, "hex");
  const b = Buffer.from(base);
  const r = int(4);
  if (r === 0 && b.length > 0) b[int(b.length)] = int(256);
  if (r === 1 && b.length > 1) {
    addDecode("t.All", b.subarray(0, int(b.length)));
    continue;
  }
  if (r === 2 && b.length > 0) b[int(b.length)] ^= 1 << int(8);
  addDecode("t.All", b);
}
const H = (s) => Buffer.from(s.replace(/\s+/g, ""), "hex");
for (const s of [
  "", "08", "0880", "08ffffffffffffffffffff01", "0001", "07", "0f00", "f8ffffff0f00",
  "fffffffff80f00", "1a03616263", "1a0561", "7a0100", "880101", "9a0103010203",
  // unknown fields of every wire type, and a group
  "f80701 f90701000000000000000000 fa070100 fd0701020304", "fb0701 fc0701", "fb0701 08 01 fc0701",
  "fb0701 fb0702 fc0702 fc0701", "fb0701 fc0702", "fc0701", "fb0701",
  // wire type mismatch (skipped), packed and unpacked repeated, oneof clearing, merges
  "1803", "92010301ff7f 900105", "9a011d 000000000000f03f 000000000000f8ff 000000000000f07f 0000000000000080",
  "9201", "9201028001", "920103ff",
  "92030161 a0030a 92030162", "9a030208 01 9a03021001", "8a010208 01 8a01021001",
  "8a01 05 0a 03 61 62 63 8a01 04 1a 02 08 05",
  // maps: missing key/value, duplicate keys, wrong wire types
  "f201 00", "f201 02 0a 00", "f201 08 0a 01 61 12 01 62 0a 01 63", "fa01 04 08 05 12 00", "fa01 02 1205",
  "8202 04 08 07 10 02", "8202 02 1009", "8a02 0b 08 01 11 000000000000f03f", "9202 04 08 ff 01 12",
  // well-known types
  "e203 06 08 80 a0 9f 9c 06", "e203 0b 08 ffffffffffffffffff01 10 01", "e203 02 10 ff ffffffff0f",
  "e203 0c 08 ffffffffffff ffffff 7f", "ea03 04 08 01 10 01", "ea03 0b 08 ffffffffffffffffff01 10 05",
  "ea03 0c 08 ffffffffffffffffff01 10 ffffffffffffffffff01", "ea03 06 08 80 e0 d0 ed 97 09",
  "f203 00", "fa03 02 0801", "fa03 09 11 000000000000f87f", "fa03 03 2a 01 0a", "8204 05 0a 03 0a 01 41",
  "8a04 07 0a 05 61 5f 62 5f 63", "9204 1b 0a 19 74 79 70 65 2e 67 6f 6f 67 6c 65 61 70 69 73 2e 63 6f 6d 2f 74 2e 49 6e 6e 65 72",
  "9204 0a 0a 08 78 2f 6e 6f 70 65 2e 58 12 00", "9204 02 12 00", "9a04 00", "a204 03 08 ff 01", "aa04 02 08 02",
  "c204 05 0d 00 00 c0 7f", "8a04 02 0a 00",
  // strings with invalid UTF-8
  "7203 c3 28 61", "7204 ed a0 80 41", "7205 f0 9f 98 80 ff", "7202 e2 82", "7203 f4 90 80",
  // nested depth
  "8a01 0a 1a 08 1a 06 1a 04 1a 02 10 01",
]) addDecode("t.All", H(s));

// frames: gRPC and gRPC-Web bodies
const frames = [];
const addFrame = (bytes) => {
  try {
    const r = new pb.FrameReader();
    const msgs = r.push(bytes);
    frames.push({ hex: hex(bytes), messages: msgs.map(hex), trailers: r.trailers, rest: r.rest });
  } catch (e) {
    frames.push({ hex: hex(bytes), error: e.message });
  }
};
for (const s of [
  "", "0000000000", "000000000208011000", "0000000002080100000000", "00000000020801 80 0000000f 67 72 70 63 2d 73 74 61 74 75 73 3a 30 0d 0a",
  "01000000020801", "8000000020 677270632d7374617475733a20350d0a677270632d6d6573736167653a206e6f",
  "800000001e 4772706333 2d537461747573 3a2031330d0a 6772 7063 2d6d6573736167653a2078",
  "00000000", "0000000005 0801", "02000000020801",
]) addFrame(H(s));

const out = path.join(root, "spec/golden/protobuf/vectors.json");
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify({ seed: SEED, count: COUNT, descriptors: d, encode: encodeCases, decode: decodeCases, frames }) + "\n");
console.log(`wrote ${out}: ${encodeCases.length} encode, ${decodeCases.length} decode, ${frames.length} frame cases`);
