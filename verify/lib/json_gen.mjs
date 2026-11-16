// Seeded random JSON documents for `dl test --json-fuzz`.
//   node json_gen.mjs <seed> <count> <inputs.bin> <expected.txt>
// inputs.bin: raw JSON texts separated by "\x1e" (a byte JSON never contains unescaped),
//   written with varied whitespace, \u escapes (including surrogate pairs) and number
//   spellings, so the decoder sees more than JSON.stringify output.
// expected.txt: one line per document, JSON.stringify semantics with object keys sorted
//   by UTF-8 bytes (what distilled.json emits).
import { writeFileSync } from "node:fs";

const [seedArg, countArg, inPath, expectedPath] = process.argv.slice(2);
let state = Number(seedArg) >>> 0;
const rand = () => {
  // mulberry32
  state = (state + 0x6d2b79f5) >>> 0;
  let t = state;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const int = (n) => Math.floor(rand() * n);
const pick = (xs) => xs[int(xs.length)];

const CHARS = [
  "a", "b", "z", "A", "0", "9", " ", "_", "-", "/", "~", "\"", "\\", "\n", "\t", "\r", "\b",
  "\f", "\u0000", "\u0001", "\u001f", "\u007f", "é", "ß", "€", "中", "\u2028", "\u2029",
  "\ufeff", "\uffff", "😀", "𝄞", "\u{10ffff}",
];
const KEYS = ["a", "b", "id", "name", "", "1", "0", "é", "Z", "a b", "😀", "x\ny", "\"q\""];

function randString() {
  const n = int(4) === 0 ? 0 : int(12);
  let s = "";
  for (let i = 0; i < n; i++) s += pick(CHARS);
  return s;
}

// number literal text; its value is whatever JSON.parse says
function randNumberText() {
  switch (int(12)) {
    case 0: return String(int(1000));
    case 1: return "-" + String(int(1000));
    case 2: return String(int(2 ** 31) * 2 ** 22 + int(2 ** 22)); // up to ~2^53
    case 3: return pick(["9007199254740992", "-9007199254740992", "9007199254740993", "12345678901234567890"]);
    case 4: return pick(["-0", "0", "0.0", "-0.0", "0e0", "1E5", "1e+5", "1.0e-5", "2E-0"]);
    case 5: return (rand() * 1000).toString();
    case 6: return (rand() - 0.5).toPrecision(1 + int(17));
    case 7: return `${1 + int(9)}.${int(1000)}e${pick(["", "+", "-"])}${int(330)}`;
    case 8: return pick(["5e-324", "2.2250738585072014e-308", "1.7976931348623157e308", "1e21", "1e-7", "1e20", "0.000001", "123456789012345680000"]);
    case 9: return String(rand() * 2 ** int(70));
    case 10: return String(-rand() / 2 ** int(30));
    default: return `${int(100)}.${String(int(100000)).padStart(int(6), "0")}`;
  }
}

const ws = () => (int(3) === 0 ? pick([" ", "\n", "\t", "\r\n", "  ", " \n\t "]) : "");

function escapeForInput(s) {
  let out = "\"";
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    const roll = int(4);
    if (ch === "\"" || ch === "\\") out += "\\" + ch;
    else if (ch === "/" && roll === 0) out += "\\/";
    else if (cp < 0x20 || roll === 0) {
      if (cp > 0xffff) {
        const hi = 0xd800 + ((cp - 0x10000) >> 10);
        const lo = 0xdc00 + ((cp - 0x10000) & 0x3ff);
        const h = (x) => x.toString(16).padStart(4, "0");
        out += int(2) ? `\\u${h(hi)}\\u${h(lo)}` : `\\u${h(hi).toUpperCase()}\\u${h(lo).toUpperCase()}`;
      } else {
        const short = { "\n": "\\n", "\t": "\\t", "\r": "\\r", "\b": "\\b", "\f": "\\f" }[ch];
        out += short && int(2) ? short : "\\u" + cp.toString(16).padStart(4, "0");
      }
    } else out += ch;
  }
  return out + "\"";
}

function randText(depth) {
  const roll = int(depth > 5 ? 6 : 10);
  if (roll === 0) return "null";
  if (roll === 1) return pick(["true", "false"]);
  if (roll === 2 || roll === 3) return randNumberText();
  if (roll === 4 || roll === 5) return escapeForInput(randString());
  if (roll < 8) {
    const n = int(5);
    const items = [];
    for (let i = 0; i < n; i++) items.push(ws() + randText(depth + 1) + ws());
    return "[" + (n ? items.join(",") : ws()) + "]";
  }
  const n = int(5);
  const items = [];
  for (let i = 0; i < n; i++) {
    const key = int(3) === 0 ? randString() : pick(KEYS);
    items.push(ws() + escapeForInput(key) + ws() + ":" + ws() + randText(depth + 1) + ws());
  }
  return "{" + (n ? items.join(",") : ws()) + "}";
}

const byteCompare = (a, b) => Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
function canonical(v) {
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  if (v !== null && typeof v === "object") {
    const keys = Object.keys(v).sort(byteCompare);
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonical(v[k])).join(",") + "}";
  }
  return JSON.stringify(v);
}

const hasInfinity = (v) =>
  typeof v === "number"
    ? !Number.isFinite(v)
    : v !== null && typeof v === "object" && Object.values(v).some(hasInfinity);

const inputs = [];
const expected = [];
const count = Number(countArg);
while (inputs.length < count) {
  const text = ws() + randText(0) + ws();
  const value = JSON.parse(text);
  const out = canonical(value);
  // distilled.json refuses to encode infinities (JSON.stringify writes null): skip them
  if (hasInfinity(value)) continue;
  inputs.push(text);
  expected.push(out);
}
// one deep document so nesting is covered too
inputs.push("[".repeat(900) + "{\"deep\":[1,null,\"x\"]}" + "]".repeat(900));
expected.push(canonical(JSON.parse(inputs[inputs.length - 1])));

writeFileSync(inPath, Buffer.from(inputs.join("\x1e"), "utf8"));
writeFileSync(expectedPath, expected.join("\n") + "\n");
