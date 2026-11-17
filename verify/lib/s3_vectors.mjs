// Writes spec/golden/s3/presign.lua: URLs and POST policies presigned by Distilled's
// packages/s3/src/presign.ts (the code distilled.s3.presign ports), and checksum headers
// computed by its middleware/checksum.ts hashers.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/s3_vectors.mjs spec/golden/s3/presign.lua
// DISTILLED_ROOT overrides ../distilled.
import * as path from "node:path";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const S3 = path.join(P, "s3/src");
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Presign = await import(path.join(S3, "presign.ts"));
const Credentials = await import(path.join(S3, "credentials.ts"));
const Region = await import(path.join(S3, "region.ts"));
const Endpoint = await import(path.join(S3, "endpoint.ts"));
const { getCrc32ChecksumAlgorithmFunction } = await import(path.join(S3, "hash/crc32.ts"));
const { getMd5ChecksumAlgorithmFunction } = await import(path.join(S3, "hash/md5.ts"));
const { stringHasher } = await import(path.join(S3, "middleware/checksum.ts"));

const out = process.argv[2];
if (!out) throw new Error("usage: s3_vectors.mjs <out.lua>");

const AKID = "AKIAIOSFODNN7EXAMPLE";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const TOKEN = "FwoGZXIvYXdzEJr//////////wEaDH+session";
const DATETIME = "20130524T000000Z";

const layerOf = (c) => {
  const layers = [
    Layer.succeed(
      Credentials.Credentials,
      Effect.succeed({
        accessKeyId: Redacted.make(AKID),
        secretAccessKey: Redacted.make(SECRET),
        sessionToken: c.session_token ? Redacted.make(TOKEN) : undefined,
        region: "us-east-1",
      }),
    ),
    Layer.succeed(Region.Region, Effect.succeed(c.layer_region ?? "us-east-1")),
  ];
  if (c.endpoint) layers.push(Layer.succeed(Endpoint.Endpoint, Effect.succeed(c.endpoint)));
  return Layer.mergeAll(...layers);
};

const run = async (c, program) => {
  const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(layerOf(c))));
  if (exit._tag === "Success") return { value: exit.value };
  const e = exit.cause.reasons?.[0]?.error ?? exit.cause.failures?.[0] ?? exit.cause;
  const err = e?.error ?? e;
  return { error: { tag: err?._tag ?? String(err), member: err?.member, message: err?.message } };
};

// presignUrl
const urlCases = [
  { name: "plain GET", url: "https://examplebucket.s3.amazonaws.com/test.txt", service: "s3" },
  {
    name: "explicit region, expiry, method",
    url: "https://examplebucket.s3.eu-west-1.amazonaws.com/a b.txt?x-id=GetObject",
    service: "s3",
    region: "eu-west-1",
    expires_in: 3600,
    method: "PUT",
  },
  {
    name: "pinned headers (content-type is signed)",
    url: "https://examplebucket.s3.amazonaws.com/up.png",
    service: "s3",
    method: "PUT",
    headers: { "content-type": "image/png", "x-amz-meta-a": "b" },
  },
  { name: "another service", url: "https://abc.execute-api.us-west-2.amazonaws.com/prod/x", service: "execute-api", region: "us-west-2" },
  { name: "session token", url: "https://examplebucket.s3.amazonaws.com/t", service: "s3", session_token: true },
];

// presignS3Url (sigv4.test.ts "Presign" cases, and more)
const s3Cases = [
  {
    name: "explicit version and special object key",
    bucket: "examplebucket",
    key: "dir/a b+%?#/雪.txt",
    version_id: "version+/= %?#&雪",
    response_content_type: "text/plain; charset=utf-8",
  },
  { name: "greedy key label", bucket: "examplebucket", key: "/a/(x)!~.txt" },
  { name: "partition us-west-2", bucket: "examplebucket", key: "a.txt", region: "us-west-2" },
  { name: "partition eusc", bucket: "examplebucket", key: "a.txt", region: "eusc-de-east-1" },
  { name: "partition cn", bucket: "examplebucket", key: "a.txt", region: "cn-north-1" },
  {
    name: "custom path-style endpoint",
    bucket: "examplebucket",
    key: "dir/a b+%.txt",
    version_id: "version+/=",
    endpoint: "http://localhost:4566/s3/",
  },
  { name: "custom endpoint keeps a/b in one segment", bucket: "a/b", key: "k", endpoint: "http://localhost:4566" },
  { name: "no version", bucket: "examplebucket", key: "dir/a b.txt" },
  {
    name: "pins content-type",
    method: "PUT",
    bucket: "examplebucket",
    key: "dir/a b.png",
    content_type: "image/png",
    expires_in: 60,
  },
  { name: "session token", bucket: "examplebucket", key: "k", session_token: true },
  { name: "empty key", bucket: "examplebucket", key: "" },
  { name: "dot-dot key", bucket: "examplebucket", key: ".." },
  { name: "dot-dot key segment", bucket: "examplebucket", key: "a/../../other/k" },
  { name: "empty bucket", bucket: "", key: "k" },
  { name: "dot-dot bucket, custom endpoint", bucket: "..", key: "k", endpoint: "http://localhost:4566" },
  { name: "bucket with a slash", bucket: "attacker.invalid/x", key: "k" },
  { name: "bucket with a hash", bucket: "attacker.invalid#", key: "k" },
  { name: "uppercase bucket", bucket: "MyBucket", key: "k" },
];

// presignPost
const postCases = [
  { name: "minimal", bucket: "uploads", key: "a.txt" },
  {
    name: "filename key, conditions, fields",
    bucket: "uploads",
    key: "avatars/${filename}",
    conditions: [["content-length-range", 0, 10485760], ["starts-with", "$Content-Type", "image/"], { acl: "private" }],
    fields: { "Content-Type": "image/png", acl: "private", "x-amz-meta-user": "u1" },
    expires_in: 3600,
  },
  {
    name: "fields as an ordered list",
    bucket: "uploads",
    key: "k",
    fields_list: [["x-amz-meta-z", "1"], ["Content-Type", "text/plain"], ["bucket", "uploads"]],
  },
  { name: "session token, region", bucket: "uploads", key: "k", session_token: true, region: "eu-west-2" },
  { name: "custom endpoint", bucket: "uploads", key: "k", endpoint: "http://localhost:9000/" },
  { name: "filename not at the end", bucket: "uploads", key: "${filename}/x" },
  { name: "invalid key", bucket: "uploads", key: "" },
];

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
    if (!v.length) return "{}";
    return `{\n${v.map((x) => `${inner}${lua(x, inner)},`).join("\n")}\n${indent}}`;
  }
  const keys = Object.keys(v).sort();
  const parts = keys.filter((k) => v[k] !== undefined).map((k) => `${inner}[${lua(k)}] = ${lua(v[k], inner)},`);
  return parts.length ? `{\n${parts.join("\n")}\n${indent}}` : "{}";
};

const result = { access_key_id: AKID, secret_access_key: SECRET, session_token: TOKEN, datetime: DATETIME };

result.url = [];
for (const c of urlCases) {
  const r = await run(
    c,
    Presign.presignUrl({
      url: c.url,
      service: c.service,
      region: c.region,
      method: c.method,
      expiresIn: c.expires_in,
      headers: c.headers,
      datetime: DATETIME,
    }),
  );
  result.url.push({ input: c, expected: r });
}

result.s3_url = [];
for (const c of s3Cases) {
  const r = await run(
    c,
    Presign.presignS3Url({
      bucket: c.bucket,
      key: c.key,
      method: c.method,
      versionId: c.version_id,
      region: c.region,
      expiresIn: c.expires_in,
      contentType: c.content_type,
      responseContentType: c.response_content_type,
      datetime: DATETIME,
    }),
  );
  result.s3_url.push({ input: c, expected: r });
}

result.post = [];
for (const c of postCases) {
  const r = await run(
    c,
    Presign.presignPost({
      bucket: c.bucket,
      key: c.key,
      region: c.region,
      expiresIn: c.expires_in,
      conditions: c.conditions,
      fields: c.fields ?? (c.fields_list && Object.fromEntries(c.fields_list)),
      datetime: DATETIME,
    }),
  );
  if (r.value) {
    // the field order Distilled returns (insertion order); Lua sorts the caller's fields
    r.value.field_list = Object.entries(r.value.fields);
    r.value.policy = Buffer.from(r.value.fields.Policy, "base64").toString("utf8");
  }
  result.post.push({ input: c, expected: r });
}

// checksums of the hashers the middleware uses (crc32, md5), and node's for the others
const bodies = ["", "a", "<Delete><Object><Key>k</Key></Object></Delete>", "x".repeat(70000), "雪\u0000\u00ff"];
result.checksum = [];
for (const body of bodies) {
  const b64 = (bytes) => Buffer.from(bytes).toString("base64");
  const crc32c = (s) => {
    let crc = 0xffffffff;
    for (const byte of Buffer.from(s, "utf8")) {
      crc ^= byte;
      for (let k = 0; k < 8; k++) crc = crc & 1 ? (crc >>> 1) ^ 0x82f63b78 : crc >>> 1;
    }
    const n = (crc ^ 0xffffffff) >>> 0;
    return b64([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
  };
  result.checksum.push({
    body,
    md5: b64(stringHasher(getMd5ChecksumAlgorithmFunction(), body)),
    crc32: b64(stringHasher(getCrc32ChecksumAlgorithmFunction(), body)),
    crc32c: crc32c(body),
    sha1: createHash("sha1").update(body).digest("base64"),
    sha256: createHash("sha256").update(body).digest("base64"),
  });
}

writeFileSync(
  out,
  "-- Generated by verify/lib/s3_vectors.mjs from Distilled's packages/s3 (presign.ts,\n" +
    "-- middleware/checksum.ts hashers). Do not edit.\nreturn " +
    lua(result) +
    "\n",
);
console.log(`wrote ${out}`);
