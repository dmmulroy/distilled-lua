// Writes spec/golden/sigv4/vectors.lua: requests signed by Distilled's SigV4 signer
// (../distilled/packages/aws4signer, the code distilled.sigv4 ports), cross-checked here
// against aws4fetch itself wherever aws4fetch has the same options, plus the published
// AWS SigV4 test suite (aws-sig-v4-test-suite, as vendored by mhart/aws4) with a flag
// saying whether Distilled reproduces the published signature.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/sigv4_vectors.mjs spec/golden/sigv4/vectors.lua
// (`verify/dl crypto-vectors` runs it). DISTILLED_ROOT overrides ../distilled.
import * as path from "node:path";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const Signer = await import(path.join(P, "aws4signer/src/index.ts"));
const Effect = await import(E + "Effect.js");
const Redacted = await import(E + "Redacted.js");
const { AwsV4Signer } = await import(
  path.join(DISTILLED, "node_modules/.pnpm/aws4fetch@1.0.20/node_modules/aws4fetch/dist/aws4fetch.esm.mjs")
);

const out = process.argv[2];
if (!out) throw new Error("usage: sigv4_vectors.mjs <out.lua>");

const AKID = "AKIAIOSFODNN7EXAMPLE";
const SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const TOKEN = "FwoGZXIvYXdzEJr//////////wEaDH+session";
const DATETIME = "20240115T120000Z";

// Cases from aws4signer/test/aws4fetch.test.ts, then edge cases for distilled.sigv4.
// `hashPayload` is Distilled's own option: those cases are not compared with aws4fetch.
const cases = [
  { name: "S3 GET, guessed from a virtual-hosted bucket", url: "https://bucket.s3.eu-west-1.amazonaws.com/a/b c+d.txt" },
  { name: "S3 global endpoint", url: "https://s3.amazonaws.com/bucket/key?versionId=1&list-type=2" },
  { name: "S3 duplicate query keys", url: "https://s3.us-east-2.amazonaws.com/b/k?a=2&a=1&b" },
  {
    name: "SQS POST with a body and session token",
    url: "https://queue.amazonaws.com/123/q",
    method: "POST",
    body: "Action=SendMessage&MessageBody=hello%20world",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    sessionToken: true,
  },
  {
    name: "DynamoDB JSON target",
    url: "https://dynamodb.us-west-2.amazonaws.com/",
    method: "POST",
    body: '{"TableName":"t"}',
    headers: { "X-Amz-Target": "DynamoDB_20120810.ListTables", "Content-Type": "application/x-amz-json-1.0" },
  },
  { name: "Lambda function URL", url: "https://abc123.lambda-url.ap-south-1.on.aws/path?x=1" },
  { name: "Cloudflare R2", url: "https://acct.r2.cloudflarestorage.com/bucket/obj%20name", method: "PUT", body: "data" },
  { name: "Backblaze B2", url: "https://bucket.s3.us-west-004.backblazeb2.com/file" },
  { name: "IoT data plane", url: "https://abc-ats.iot.eu-central-1.amazonaws.com/things/x/shadow" },
  {
    name: "IoT device gateway presign appends the token",
    url: "https://abc-ats.iot.us-east-1.amazonaws.com/mqtt",
    signQuery: true,
    sessionToken: true,
  },
  { name: "FIPS host", url: "https://kms-fips.us-east-1.amazonaws.com/", method: "POST", body: "{}" },
  { name: "dual-stack S3", url: "https://bucket.s3.dualstack.us-east-1.amazonaws.com/k" },
  { name: "GovCloud", url: "https://sts.us-gov.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15" },
  {
    name: "explicit service and region over a custom host",
    url: "https://minio.internal:9000/bucket/k",
    service: "s3",
    region: "us-east-1",
  },
  {
    name: "API Gateway path with reserved characters",
    url: "https://abc.execute-api.us-east-1.amazonaws.com/prod/a!b'c(d)*e//f",
    service: "execute-api",
  },
  {
    name: "presigned S3 URL with a session token",
    url: "https://bucket.s3.us-east-1.amazonaws.com/k?X-Amz-Expires=600",
    signQuery: true,
    sessionToken: true,
  },
  {
    name: "allHeaders signs content-type and range",
    url: "https://bucket.s3.us-east-1.amazonaws.com/k",
    headers: { Range: "bytes=0-9", "Content-Type": "text/plain", "X-Custom": "  a   b  " },
    allHeaders: true,
  },
  {
    name: "appendSessionToken on a normal service",
    url: "https://execute-api.us-east-1.amazonaws.com/x",
    signQuery: true,
    sessionToken: true,
    appendSessionToken: true,
  },
  {
    name: "singleEncode keeps %2F and encodes once",
    url: "https://es.us-east-1.amazonaws.com/idx/_doc/a%2Fb",
    service: "es",
    region: "us-east-1",
    singleEncode: true,
  },
  {
    name: "autoscaling plans from X-Amz-Target",
    url: "https://autoscaling.us-east-1.amazonaws.com/",
    method: "POST",
    body: "{}",
    headers: { "X-Amz-Target": "AnyScaleScalingPlannerFrontendService.DescribeScalingPlans" },
  },
  // ---- edge cases (distilled-lua) ----
  { name: "dot segments are resolved", url: "https://sqs.us-east-1.amazonaws.com/a/./b/../c/%2e%2E/d" },
  { name: "S3 keeps dot segments it decodes", url: "https://b.s3.us-east-1.amazonaws.com/a/%2e%2e/k" },
  {
    name: "query: plus, encoded space, empty key, key without value, empty pairs",
    url: "https://sqs.us-east-1.amazonaws.com/q?b=x+y&a=%20z&=empty&flag&&c=*!'()~",
  },
  { name: "query: invalid UTF-8 escape becomes U+FFFD", url: "https://sqs.us-east-1.amazonaws.com/q?k=%FF%C3&%E2%82=v" },
  { name: "query: bad percent escapes stay literal", url: "https://sqs.us-east-1.amazonaws.com/q?k=%zz%4&x=%" },
  { name: "S3 path with an invalid escape is used as it is", url: "https://b.s3.us-east-1.amazonaws.com/a%ZZb/%FF" },
  { name: "UTF-8 path and query", url: "https://execute-api.us-east-1.amazonaws.com/caf\u00e9/\u65e5\u672c?q=\u00fc\u00df&\u2603=1" },
  { name: "S3 UTF-8 key with plus and space", url: "https://b.s3.us-west-2.amazonaws.com/f\u00f6o/a+b c%2Bd" },
  {
    name: "header whitespace is trimmed and runs collapse",
    url: "https://sqs.us-east-1.amazonaws.com/",
    headers: { "X-Amz-Meta-A": " one  two\t\tthree ", "x-amz-meta-b": "tab\there", "X-Empty": "" },
  },
  {
    name: "unsignable headers are left out unless allHeaders",
    url: "https://sqs.us-east-1.amazonaws.com/",
    headers: {
      "User-Agent": "lua",
      Expect: "100-continue",
      "X-Amzn-Trace-Id": "Root=1",
      Range: "bytes=1-2",
      "Content-Length": "4",
      "Presigned-Expires": "1",
      Connection: "close",
      Authorization: "old",
      "X-Kept": "yes",
    },
  },
  {
    name: "a Host header is replaced by the URL's host",
    url: "https://sqs.us-east-1.amazonaws.com/",
    headers: { Host: "evil.example.com" },
  },
  { name: "default port is dropped, others kept", url: "https://sqs.us-east-1.amazonaws.com:443/x", service: "sqs" },
  { name: "custom port is signed in host", url: "http://localhost:4566/q", service: "sqs", region: "us-east-1" },
  { name: "scheme and host are lower-cased", url: "HTTPS://SQS.US-EAST-1.AMAZONAWS.COM/Path", service: "sqs", region: "us-east-1" },
  { name: "a fragment is kept in the URL and not signed", url: "https://sqs.us-east-1.amazonaws.com/x?a=1#frag" },
  { name: "an empty query keeps its question mark", url: "https://sqs.us-east-1.amazonaws.com/x?" },
  { name: "lower-case method is upper-cased only in the canonical request", url: "https://sqs.us-east-1.amazonaws.com/x", method: "put", body: "x" },
  {
    name: "binary body",
    url: "https://execute-api.us-east-1.amazonaws.com/upload",
    method: "POST",
    bodyHex: "00ff10e2828280c3",
  },
  {
    name: "session token in header mode",
    url: "https://sts.us-east-1.amazonaws.com/",
    method: "POST",
    body: "Action=GetCallerIdentity&Version=2011-06-15",
    headers: { "content-type": "application/x-www-form-urlencoded; charset=utf-8" },
    sessionToken: true,
  },
  {
    name: "explicit x-amz-content-sha256 is the payload hash",
    url: "https://execute-api.us-east-1.amazonaws.com/stream",
    method: "POST",
    headers: { "X-Amz-Content-Sha256": "UNSIGNED-PAYLOAD" },
    body: "ignored",
  },
  {
    name: "S3 presign of a PUT with an existing query and a body",
    url: "https://b.s3.us-east-1.amazonaws.com/k?uploadId=abc&partNumber=2",
    method: "PUT",
    body: "part",
    signQuery: true,
  },
  {
    name: "presign outside S3 has no default X-Amz-Expires",
    url: "https://execute-api.us-east-1.amazonaws.com/x?a=b c",
    signQuery: true,
  },
  {
    name: "S3 presign with x-amz-content-sha256 set",
    url: "https://b.s3.us-east-1.amazonaws.com/k",
    headers: { "x-amz-content-sha256": "abc" },
    signQuery: true,
  },
  {
    name: "duplicate query keys outside S3 are all signed",
    url: "https://sqs.us-east-1.amazonaws.com/?a=2&a=1&a=1&b=&b",
  },
  {
    name: "hashPayload outside S3",
    url: "https://execute-api.us-east-1.amazonaws.com/x",
    method: "POST",
    body: '{"a":1}',
    hashPayload: true,
  },
  {
    name: "hashPayload on S3 (no UNSIGNED-PAYLOAD)",
    url: "https://b.s3.us-east-1.amazonaws.com/k",
    method: "PUT",
    body: "hello",
    hashPayload: true,
  },
  {
    name: "hashPayload with no body hashes the empty string",
    url: "https://b.s3.us-east-1.amazonaws.com/k",
    hashPayload: true,
  },
  {
    name: "no body defaults the method to GET, a body to POST",
    url: "https://execute-api.us-east-1.amazonaws.com/x",
    body: "payload",
  },
  { name: "unknown host, region defaults to us-east-1", url: "https://example.com/x", service: "custom" },
  { name: "path of only slashes outside S3", url: "https://sqs.us-east-1.amazonaws.com//a///b//" },
  { name: "credentials-free path chars: ~ and %7E", url: "https://sqs.us-east-1.amazonaws.com/~a/%7Eb" },
  { name: "query with an encoded ampersand and equals", url: "https://sqs.us-east-1.amazonaws.com/?a=1%262&b%3D=3" },
];

// The published AWS SigV4 test suite (service "service", us-east-1, 20150830T123600Z).
// Duplicate and multi-line header cases are left out: a Lua header table has one value
// per name, and aws4fetch joins repeated headers with ", " where the suite uses ",".
const SUITE_SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";
const STS_TOKEN =
  "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==";
const sig = (signed, s) =>
  `AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=${signed}, Signature=${s}`;
const suite = [
  ["get-vanilla", "GET", "/", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-vanilla-query", "GET", "/", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-vanilla-empty-query-key", "GET", "/?Param1=value1", {}, "", sig("host;x-amz-date", "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb")],
  ["get-vanilla-query-order-key", "GET", "/?Param1=value2&Param1=Value1", {}, "", sig("host;x-amz-date", "eedbc4e291e521cf13422ffca22be7d2eb8146eecf653089df300a15b2382bd1")],
  ["get-vanilla-query-order-key-case", "GET", "/?Param2=value2&Param1=value1", {}, "", sig("host;x-amz-date", "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")],
  ["get-vanilla-query-order-value", "GET", "/?Param1=value2&Param1=value1", {}, "", sig("host;x-amz-date", "5772eed61e12b33fae39ee5e7012498b51d56abc0abb7c60486157bd471c4694")],
  ["get-vanilla-query-unreserved", "GET", "/?-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz=-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", {}, "", sig("host;x-amz-date", "9c3e54bfcdf0b19771a7f523ee5669cdf59bc7cc0884027167c21bb143a40197")],
  ["get-vanilla-utf8-query", "GET", "/?\u1234=bar", {}, "", sig("host;x-amz-date", "2cdec8eed098649ff3a119c94853b13c643bcf08f8b0a1d91e12c9027818dd04")],
  ["get-unreserved", "GET", "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", {}, "", sig("host;x-amz-date", "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f")],
  ["get-utf8", "GET", "/\u1234", {}, "", sig("host;x-amz-date", "8318018e0b0f223aa2bbf98705b62bb787dc9c0e678f255a891fd03141be5d85")],
  ["get-header-value-trim", "GET", "/", { "My-Header1": " value1", "My-Header2": ' "a   b   c"' }, "", sig("host;my-header1;my-header2;x-amz-date", "acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736")],
  ["post-vanilla", "POST", "/", {}, "", sig("host;x-amz-date", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")],
  ["post-vanilla-query", "POST", "/?Param1=value1", {}, "", sig("host;x-amz-date", "28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11")],
  ["post-vanilla-empty-query-value", "POST", "/?Param1=value1", {}, "", sig("host;x-amz-date", "28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11")],
  ["post-header-key-case", "POST", "/", {}, "", sig("host;x-amz-date", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")],
  ["post-header-key-sort", "POST", "/", { "My-Header1": "value1" }, "", sig("host;my-header1;x-amz-date", "c5410059b04c1ee005303aed430f6e6645f61f4dc9e1461ec8f8916fdf18852c")],
  ["post-header-value-case", "POST", "/", { "My-Header1": "VALUE1" }, "", sig("host;my-header1;x-amz-date", "cdbc9802e29d2942e5e10b5bccfdd67c5f22c7c4e8ae67b53629efa58b974b7d")],
  ["post-x-www-form-urlencoded", "POST", "/", { "Content-Type": "application/x-www-form-urlencoded" }, "Param1=value1", sig("content-type;host;x-amz-date", "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a")],
  ["post-x-www-form-urlencoded-parameters", "POST", "/", { "Content-Type": "application/x-www-form-urlencoded; charset=utf8" }, "Param1=value1", sig("content-type;host;x-amz-date", "1a72ec8f64bd914b0e42e42607c7fbce7fb2c7465f63e3092b3b0d39fa77a6fe")],
  ["get-relative", "GET", "/example/..", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-relative-relative", "GET", "/example1/example2/../..", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-slash", "GET", "//", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-slash-dot-slash", "GET", "/./", {}, "", sig("host;x-amz-date", "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")],
  ["get-slash-pointless-dot", "GET", "/./example", {}, "", sig("host;x-amz-date", "ef75d96142cf21edca26f06005da7988e4f8dc83a165a80865db7089db637ec5")],
  ["get-slashes", "GET", "//example//", {}, "", sig("host;x-amz-date", "9a624bd73a37c9a373b5312afbebe7a714a789de108f0bdfe846570885f57e84")],
  ["get-space", "GET", "/example space/", {}, "", sig("host;x-amz-date", "652487583200325589f1fba4c7e578f72c47cb61beeca81406b39ddec1366741")],
  ["post-sts-header-before", "POST", "/", {}, "", sig("host;x-amz-date;x-amz-security-token", "85d96828115b5dc0cfc3bd16ad9e210dd772bbebba041836c64533a82be05ead"), STS_TOKEN],
  ["post-sts-header-after", "POST", "/", {}, "", sig("host;x-amz-date", "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"), STS_TOKEN, true],
];

const bodyOf = (c) => (c.bodyHex !== undefined ? Buffer.from(c.bodyHex, "hex") : c.body);

const distilled = async (c, extra = {}) => {
  const options = Signer.guessScope({
    url: c.url,
    method: c.method,
    headers: c.headers,
    body: bodyOf(c),
    accessKeyId: c.accessKeyId ?? AKID,
    secretAccessKey: Redacted.make(c.secret ?? SECRET),
    sessionToken: c.sessionToken ? Redacted.make(c.token ?? TOKEN) : undefined,
    service: c.service,
    region: c.region,
    datetime: c.datetime ?? DATETIME,
    signQuery: c.signQuery,
    allHeaders: c.allHeaders,
    hashPayload: c.hashPayload,
    appendSessionToken: c.appendSessionToken,
    singleEncode: c.singleEncode,
    ...extra,
  });
  const signed = await Effect.runPromise(Signer.sign(options));
  return { method: signed.method, url: signed.url, headers: signed.headers };
};

const aws4fetchOptions = (c) => ({
    url: c.url,
    method: c.method,
    headers: c.headers,
    body: bodyOf(c),
    accessKeyId: AKID,
    secretAccessKey: SECRET,
    sessionToken: c.sessionToken ? TOKEN : undefined,
    service: c.service,
    region: c.region,
    datetime: DATETIME,
    signQuery: c.signQuery,
    allHeaders: c.allHeaders,
    appendSessionToken: c.appendSessionToken,
    singleEncode: c.singleEncode,
});

// the canonical request aws4fetch hashes (a fresh signer: sign() changes the URL)
const canonicalOf = (c) => new AwsV4Signer(aws4fetchOptions(c)).canonicalString();

const aws4fetch = async (c) => {
  const signed = await new AwsV4Signer(aws4fetchOptions(c)).sign();
  return {
    method: signed.method,
    url: signed.url.toString(),
    headers: Object.fromEntries([...signed.headers].sort(([a], [b]) => (a < b ? -1 : 1))),
  };
};

// Lua literal of a JSON-like value (strings are escaped byte by byte: valid Lua 5.1)
const lua = (v, indent = "") => {
  if (v === undefined || v === null) return "nil";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") {
    let s = '"';
    for (const b of Buffer.from(v, "utf8")) {
      if (b === 0x22) s += '\\"';
      else if (b === 0x5c) s += "\\\\";
      else if (b >= 0x20 && b < 0x7f) s += String.fromCharCode(b);
      else s += "\\" + String(b).padStart(3, "0"); // \ddd: never runs into a following digit
    }
    return s + '"';
  }
  const inner = indent + "  ";
  const keys = Object.keys(v).sort();
  const parts = keys
    .filter((k) => v[k] !== undefined)
    .map((k) => `${inner}[${lua(k)}] = ${lua(v[k], inner)},`);
  return parts.length ? `{\n${parts.join("\n")}\n${indent}}` : "{}";
};

const lines = [];
lines.push("-- Generated by verify/lib/sigv4_vectors.mjs. Do not edit.");
lines.push("-- Requests signed by Distilled's aws4signer (checked against aws4fetch where it has the");
lines.push("-- same options) and the published AWS SigV4 test suite.");
lines.push("return {");
lines.push(`  access_key_id = ${lua(AKID)},`);
lines.push(`  secret_access_key = ${lua(SECRET)},`);
lines.push(`  session_token = ${lua(TOKEN)},`);
lines.push(`  datetime = ${lua(DATETIME)},`);
lines.push("  cases = {");
let mismatches = 0;
for (const c of cases) {
  const ours = await distilled(c);
  let checked = false;
  let canonical;
  if (!c.hashPayload) {
    canonical = await canonicalOf(c);
    const theirs = await aws4fetch(c);
    if (JSON.stringify(theirs) !== JSON.stringify(ours)) {
      mismatches++;
      console.error(`aws4fetch differs from Distilled on "${c.name}"`, ours, theirs);
    }
    checked = true;
  }
  const input = {
    name: c.name,
    url: c.url,
    method: c.method,
    headers: c.headers,
    body: c.body,
    body_hex: c.bodyHex,
    service: c.service,
    region: c.region,
    session_token: c.sessionToken,
    sign_query: c.signQuery,
    all_headers: c.allHeaders,
    hash_payload: c.hashPayload,
    append_session_token: c.appendSessionToken,
    single_encode: c.singleEncode,
    aws4fetch_checked: checked,
  };
  if (canonical !== undefined) ours.canonical = canonical;
  lines.push(`    { input = ${lua(input, "    ")}, expected = ${lua(ours, "    ")} },`);
}
lines.push("  },");
lines.push("  suite = {");
let reproduced = 0;
for (const [name, method, pathQuery, headers, body, published, token, append] of suite) {
  const all = Object.keys(headers).some((h) => h.toLowerCase() === "content-type");
  const c = {
    url: "https://example.amazonaws.com" + pathQuery,
    method,
    headers,
    body,
    service: "service",
    region: "us-east-1",
    accessKeyId: "AKIDEXAMPLE",
    secret: SUITE_SECRET,
    datetime: "20150830T123600Z",
    allHeaders: all,
    sessionToken: token !== undefined,
    token,
    appendSessionToken: append,
  };
  const ours = await distilled(c);
  const same = ours.headers.authorization === published;
  if (same) reproduced++;
  const input = { name, method, url: c.url, headers, body, all_headers: all, session_token: token, append_session_token: append };
  lines.push(
    `    { input = ${lua(input, "    ")}, published = ${lua(published)}, distilled = ${lua(ours.headers.authorization)}, reproduced = ${same} },`,
  );
}
lines.push("  },");
const guesses = [
  "https://sqs.eu-west-1.amazonaws.com/",
  "https://queue.amazonaws.com/",
  "https://email.us-east-1.amazonaws.com/",
  "https://bucket.s3.amazonaws.com/",
  "https://s3-external-1.amazonaws.com/",
  "https://bucket.s3-accelerate.amazonaws.com/",
  "https://iot.us-east-1.amazonaws.com/",
  "https://data.jobs.iot.us-east-1.amazonaws.com/",
  "https://acct.r2.cloudflarestorage.com/",
  "https://s3.eu-central-003.backblazeb2.com/",
  "https://x.lambda-url.us-east-1.on.aws/",
  "https://example.com/",
  "https://s3-us-west-2.amazonaws.com/b",
  "https://s3-fips-us-gov-west-1.amazonaws.com/",
  "https://kms-fips.us-east-1.amazonaws.com/",
  "https://abc.iot.us-east-1.amazonaws.com/mqtt",
  "https://abc.iot.us-east-1.amazonaws.com/topics",
  "https://monitoring.us-east-1.amazonaws.com.cn/",
  "https://ec2.cn-north-1.amazonaws.com.cn/",
  "https://us-east-1.ec2.amazonaws.com/",
  "https://bucket.s3.dualstack.eu-west-1.amazonaws.com/",
  "https://autoscaling.us-east-1.amazonaws.com/",
  "https://mobile.us-east-1.amazonaws.com/",
  "https://x.on.aws/",
  "https://f00.backblazeb2.com/",
  "https://personalize-runtime.us-west-2.amazonaws.com/",
  "https://git-codecommit.us-east-1.amazonaws.com/",
];
lines.push("  guesses = {");
for (const u of guesses) {
  const [service, region] = Signer.guessServiceRegion(new URL(u));
  lines.push(`    { ${lua(u)}, ${lua(service)}, ${lua(region)} },`);
}
for (const [target, u] of [
  ["AnyScaleFrontendService.DescribeScalableTargets", "https://autoscaling.us-east-1.amazonaws.com/"],
  ["AnyScaleScalingPlannerFrontendService.DescribeScalingPlans", "https://autoscaling.us-east-1.amazonaws.com/"],
]) {
  const [service, region] = Signer.guessServiceRegion(new URL(u), { "X-Amz-Target": target });
  lines.push(`    { ${lua(u)}, ${lua(service)}, ${lua(region)}, ${lua(target)} },`);
}
lines.push("  },");
// presign (Signer.presign): expiresIn written into X-Amz-Expires, service/region guessed
const presigned = await Effect.runPromise(
  Signer.presign({
    url: "https://bucket.s3.us-east-1.amazonaws.com/report.pdf",
    accessKeyId: AKID,
    secretAccessKey: Redacted.make(SECRET),
    datetime: DATETIME,
    expiresIn: 3600,
  }),
);
const presignedToken = await Effect.runPromise(
  Signer.presign({
    url: "https://execute-api.us-east-1.amazonaws.com/x?b=1",
    method: "POST",
    accessKeyId: AKID,
    secretAccessKey: Redacted.make(SECRET),
    sessionToken: Redacted.make(TOKEN),
    datetime: DATETIME,
    expiresIn: 60.9,
  }),
);
lines.push("  presign = {");
lines.push(`    { url = "https://bucket.s3.us-east-1.amazonaws.com/report.pdf", expires_in = 3600, expected = ${lua(presigned)} },`);
lines.push(`    { url = "https://execute-api.us-east-1.amazonaws.com/x?b=1", method = "POST", session_token = true, expires_in = 60.9, expected = ${lua(presignedToken)} },`);
lines.push("  },");
lines.push("}");
writeFileSync(out, lines.join("\n") + "\n");
console.log(`wrote ${out}: ${cases.length} cases, suite ${reproduced}/${suite.length} reproduced by Distilled`);
if (mismatches) {
  console.error(`${mismatches} case(s) where aws4fetch and Distilled differ`);
  process.exit(1);
}
