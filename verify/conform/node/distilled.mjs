// Distilled, imported by path (never modified). Run every script here with
//   node --conditions=bun --experimental-transform-types --no-warnings <script>
// DISTILLED_ROOT overrides the checkout location (default: ../distilled next to this repo).
import * as path from "node:path";
import * as fs from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(here, "../../..");
export const DISTILLED =
  process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const imp = (p) => import(p);
export const Neon = await imp(path.join(P, "neon/src/index.ts"));
export const API = await imp(path.join(P, "core/src/api.ts"));
export const Category = await imp(path.join(P, "core/src/category.ts"));
export const Retry = await imp(path.join(P, "core/src/retry.ts"));
export const Effect = await imp(E + "Effect.js");
export const Layer = await imp(E + "Layer.js");
export const Redacted = await imp(E + "Redacted.js");
export const Fiber = await imp(E + "Fiber.js");
export const Duration = await imp(E + "Duration.js");
export const Stream = await imp(E + "Stream.js");
export const TestClock = await imp(E + "testing/TestClock.js");
export const Clock = await imp(E + "Clock.js");
export const HttpClient = await imp(E + "http/HttpClient.js");
export const HttpClientResponse = await imp(E + "http/HttpClientResponse.js");
export const HttpClientError = await imp(E + "http/HttpClientError.js");

export const BASE_URL = "https://api.conform.test/v2";
export const API_KEY = "conform-key-0123";

/** JSON case value -> TypeScript input: { "$secret": v } becomes Redacted.make(v). */
export const toInput = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(toInput);
  const keys = Object.keys(v);
  if (keys.length === 1 && keys[0] === "$secret" && typeof v.$secret === "string")
    return Redacted.make(v.$secret);
  const out = {};
  for (const k of keys) out[k] = toInput(v[k]);
  return out;
};

export const readLines = (file) =>
  fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l));

export const writeLines = (file, list) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, list.map((v) => JSON.stringify(v)).join("\n") + "\n");
};

export const plain = (v) => (Redacted.isRedacted(v) ? Redacted.value(v) : v);
