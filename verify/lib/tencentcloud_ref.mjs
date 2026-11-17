// Writes spec/golden/tencentcloud/ref.json: what Distilled's Tencent Cloud SDK
// (../distilled/packages/tencentcloud, the code distilled.protocol.tencentcloud ports)
// does, for spec/tencentcloud_conform_spec.lua to compare in lua, luajit and Rex:
//
// - signer: TC3-HMAC-SHA256 vectors from Distilled's signer.ts, each cross-checked here
//   against an independent node:crypto implementation of the documented algorithm;
// - requests: sample operations of several products run over a stub HttpClient, the
//   request captured (method, URL, headers, body), credentials fixed, a TestClock at
//   1700000000 s (the X-TC-Timestamp and the signature's date);
// - responses: canned responses through cvm describeInstances (and others), the outcome
//   (value, or the error's tag, categories, retryable, code, message, requestId, ...).
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/tencentcloud_ref.mjs spec/golden/tencentcloud/ref.json
// (`verify/dl tencentcloud-ref` runs it). DISTILLED_ROOT overrides ../distilled.
//
// Inputs are written with their keys sorted at every level: Lua tables have no insertion
// order and distilled.json writes object keys sorted, so the same input gives the same
// body bytes, and so the same signature, on both sides.
import * as path from "node:path";
import * as crypto from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";
const TC = await import(path.join(P, "tencentcloud/src/index.ts"));
const Signer = await import(path.join(P, "tencentcloud/src/signer.ts"));
const Category = await import(path.join(P, "core/src/category.ts"));
const RV = await import(path.join(P, "core/src/response-validation.ts"));
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Fiber = await import(E + "Fiber.js");
const Duration = await import(E + "Duration.js");
const TestClock = await import(E + "testing/TestClock.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");

const out = process.argv[2];
if (!out) throw new Error("usage: tencentcloud_ref.mjs <out.json>");

const EPOCH_MS = 1700000000000;
Date.now = () => EPOCH_MS;
Math.random = () => 0.5;

const SECRET_ID = "AKIDconform0123456789";
const SECRET_KEY = "conform-secret-key-7f3a";
const SESSION_TOKEN = "sts-session-token-xyz";

const sortKeys = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(sortKeys);
  const o = {};
  for (const k of Object.keys(v).sort()) o[k] = sortKeys(v[k]);
  return o;
};

// ---------------------------------------------------------------------------------
// signer vectors
// ---------------------------------------------------------------------------------

/** The documented algorithm with node:crypto, independent of signer.ts. */
const nodeSign = (i) => {
  const sha = (s) => crypto.createHash("sha256").update(s, "utf8").digest("hex");
  const hmac = (k, s) => crypto.createHmac("sha256", k).update(s, "utf8").digest();
  const values = { "content-type": i.contentType, host: i.host, "x-tc-action": i.action };
  const names = [...new Set(i.signedHeaders ?? ["content-type", "host", "x-tc-action"])].sort();
  const ch = names.map((n) => `${n}:${values[n].trim().toLowerCase()}\n`).join("");
  const cr = ["POST", "/", "", ch, names.join(";"), sha(i.payload)].join("\n");
  const d = new Date(i.timestamp * 1000);
  const date = `${d.getUTCFullYear().toString().padStart(4, "0")}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
  const scope = `${date}/${i.service}/tc3_request`;
  const sts = ["TC3-HMAC-SHA256", String(i.timestamp), scope, sha(cr)].join("\n");
  const k = hmac(hmac(hmac(Buffer.from("TC3" + i.secretKey, "utf8"), date), i.service), "tc3_request");
  return crypto.createHmac("sha256", k).update(sts, "utf8").digest("hex");
};

const DOC = {
  secretId: "AKID********************************",
  secretKey: "********************************",
  service: "cvm",
  host: "cvm.tencentcloudapi.com",
  action: "DescribeInstances",
  timestamp: 1551113065,
  contentType: "application/json; charset=utf-8",
  payload: '{"Limit": 1, "Filters": [{"Values": ["unnamed"], "Name": "instance-name"}]}',
};
const signerCases = [
  { name: "the documented example (content-type;host)", ...DOC, signedHeaders: ["content-type", "host"] },
  { name: "the documented request, default signed headers", ...DOC },
  { name: "signed headers deduplicated and sorted", ...DOC, signedHeaders: ["x-tc-action", "host", "content-type", "host"] },
  { name: "empty payload", ...DOC, payload: "" },
  { name: "empty object payload", ...DOC, payload: "{}", service: "dnspod", host: "dnspod.tencentcloudapi.com", action: "DescribeDomainList" },
  { name: "UTF-8 payload", ...DOC, payload: '{"InstanceName":"测试-é-😀","Tags":[]}' },
  { name: "a 70 KB payload", ...DOC, payload: JSON.stringify({ Data: "x".repeat(70000) }) },
  { name: "epoch 0", ...DOC, timestamp: 0 },
  { name: "one second before UTC midnight", ...DOC, timestamp: 1551139199 },
  { name: "UTC midnight", ...DOC, timestamp: 1551139200 },
  { name: "leap day 2024", ...DOC, timestamp: 1709251199 },
  { name: "2000-03-01", ...DOC, timestamp: 951868800 },
  { name: "year 2100", ...DOC, timestamp: 4102444800 },
  { name: "secret key with UTF-8 and symbols", ...DOC, secretKey: "kéy/+=\"\\ 秘密" },
  { name: "host with a port, padded content type", ...DOC, host: "127.0.0.1:8080", contentType: "  Application/JSON; charset=UTF-8 " },
  { name: "mixed-case action is lower-cased in the canonical headers", ...DOC, action: "RunInstances" },
];
const signer = [];
for (const c of signerCases) {
  const { name, ...input } = c;
  const s = await Effect.runPromise(Signer.sign({ ...input, secretKey: Redacted.make(input.secretKey) }));
  const independent = nodeSign(input);
  if (independent !== s.signature) throw new Error(`signer.ts and node:crypto disagree on ${name}`);
  signer.push({
    name,
    input: {
      secret_id: input.secretId,
      secret_key: input.secretKey,
      service: input.service,
      host: input.host,
      action: input.action,
      timestamp: input.timestamp,
      content_type: input.contentType,
      payload: input.payload,
      signed_headers: input.signedHeaders,
    },
    out: {
      authorization: s.authorization,
      signature: s.signature,
      canonical_request: s.canonicalRequest,
      string_to_sign: s.stringToSign,
      credential_scope: s.credentialScope,
    },
  });
}
if (Signer.utcDate(1551113065) !== "2019-02-25") throw new Error("utcDate");

// ---------------------------------------------------------------------------------
// operations over a stub HttpClient
// ---------------------------------------------------------------------------------

const products = {};
const product = async (name) =>
  (products[name] ??= await import(path.join(P, `tencentcloud/src/services/${name}.ts`)));

const credsLayer = (c = {}) =>
  TC.credentials({
    secretId: SECRET_ID,
    secretKey: Redacted.make(SECRET_KEY),
    sessionToken: c.session_token ? Redacted.make(SESSION_TOKEN) : undefined,
    region: c.region,
    rootDomain: c.root_domain,
  });
const noRetry = Layer.succeed(TC.Retry.Retry, { while: () => false });
const validationLayer = (mode) =>
  mode === "strict" ? RV.strict : mode === "additional" ? RV.additionalProperties : RV.lenient;

const stub = (reply, captured) =>
  Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() => {
        const body = request.body?.body;
        captured.push({
          method: request.method,
          url: request.url,
          headers: { ...request.headers },
          body: body ? new TextDecoder().decode(body) : null,
        });
        return HttpClientResponse.fromWeb(
          request,
          new Response(reply.body ?? null, { status: reply.status ?? 200, headers: reply.headers ?? {} }),
        );
      }),
    ),
  );

const runVirtual = (effect, ...layers) =>
  Effect.runPromise(
    Effect.gen(function* () {
      yield* TestClock.setTime(EPOCH_MS);
      const fiber = yield* Effect.forkChild(Effect.result(effect));
      yield* TestClock.adjust(Duration.hours(1));
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(Layer.mergeAll(TestClock.layer(), ...layers))),
  );

const view = (v) => {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object") return v;
  if (Redacted.isRedacted(v)) return { $redacted: view(Redacted.value(v)) };
  if (Array.isArray(v)) return v.map(view);
  const o = {};
  for (const [k, x] of Object.entries(v)) if (x !== undefined) o[k] = view(x);
  return o;
};
const errorView = (e) => {
  const cats = Object.keys(e[Category.categoriesKey] ?? {}).sort();
  const r = e[Category.retryableKey];
  const ra = e.retryAfter;
  return {
    tag: e._tag ?? e.constructor?.name,
    categories: cats,
    retryable: r !== undefined,
    throttling: r?.throttling === true,
    status: e.status,
    code: e.code,
    message: e.message,
    request_id: e.requestId,
    retry_after: ra === undefined ? undefined : Duration.toMillis(ra) / 1000,
    body: view(e.body),
  };
};

const run = async (c) => {
  const mod = await product(c.product);
  const op = mod[c.op];
  if (!op) throw new Error(`no ${c.product}.${c.op}`);
  const captured = [];
  const reply = c.response ?? { status: 200, body: JSON.stringify({ Response: { RequestId: "req-ok" } }) };
  const result = await runVirtual(
    op(sortKeys(c.input ?? {})),
    credsLayer(c.creds),
    noRetry,
    stub(reply, captured),
    validationLayer(c.validation),
  );
  return {
    request: captured[0],
    outcome:
      result._tag === "Success"
        ? { ok: true, value: view(result.success) ?? null }
        : { ok: false, error: errorView(result.failure) },
  };
};

// requests: product, TS export, Lua method, input, credentials
const requestCases = [
  { id: "cvm-describe-instances", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: { region: "ap-guangzhou", Limit: 1, InstanceIds: ["ins-1"] } },
  { id: "cvm-describe-instances-filters", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: { Filters: [{ Name: "instance-name", Values: ["unnamed", "测试"] }], Offset: 0, Limit: 100 },
    creds: { region: "ap-shanghai" } },
  { id: "cvm-describe-instances-empty", product: "cvm", op: "describeInstances", method: "describe_instances", input: {} },
  { id: "cvm-region-input-wins", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: { region: "ap-beijing" }, creds: { region: "ap-guangzhou" } },
  { id: "cvm-session-token", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: {}, creds: { session_token: true, region: "na-siliconvalley" } },
  { id: "cvm-root-domain", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: { Limit: 5 }, creds: { root_domain: "internal.tencentcloudapi.com" } },
  { id: "cvm-run-instances", product: "cvm", op: "runInstances", method: "run_instances",
    input: {
      region: "ap-guangzhou",
      InstanceChargeType: "POSTPAID_BY_HOUR",
      Placement: { Zone: "ap-guangzhou-3", ProjectId: 0 },
      InstanceType: "S5.MEDIUM2",
      ImageId: "img-pmqg1cw7",
      SystemDisk: { DiskType: "CLOUD_PREMIUM", DiskSize: 50 },
      DataDisks: [{ DiskType: "CLOUD_SSD", DiskSize: 100, DeleteWithInstance: true }],
      InternetAccessible: { InternetChargeType: "TRAFFIC_POSTPAID_BY_HOUR", InternetMaxBandwidthOut: 10, PublicIpAssigned: true },
      InstanceCount: 2,
      InstanceName: "web-{R:1}",
      LoginSettings: { Password: "P@ssw0rd\"\\/" },
      TagSpecification: [{ ResourceType: "instance", Tags: [{ Key: "env", Value: "prod é" }] }],
      DryRun: false,
      UserData: "IyEvYmluL2Jhc2gK",
    } },
  { id: "vpc-create-vpc", product: "vpc", op: "createVpc", method: "create_vpc",
    input: { region: "ap-singapore", VpcName: "main", CidrBlock: "10.0.0.0/16", EnableMulticast: "false", DnsServers: [] } },
  { id: "dnspod-not-regional", product: "dnspod", op: "describeDomainList", method: "describe_domain_list", input: {} },
  { id: "dnspod-session-token", product: "dnspod", op: "describeDomainList", method: "describe_domain_list",
    input: { Type: "ALL", Offset: 0, Limit: 20, Keyword: "example.com" }, creds: { session_token: true } },
  { id: "cbs-describe-disks", product: "cbs", op: "describeDisks", method: "describe_disks",
    input: { region: "ap-guangzhou", DiskIds: ["disk-1", "disk-2"], Limit: 50, ReturnBindAutoSnapshotPolicy: true } },
  { id: "cam-list-users", product: "cam", op: "listUsers", method: "list_users", input: {} },
  { id: "tag-get-resources", product: "tag", op: "getResources", method: "get_resources",
    input: { TagFilters: [{ TagKey: "env", TagValue: ["prod", "dev"] }], MaxResults: 10, PaginationToken: "" } },
  { id: "ssl-describe-certificates", product: "ssl", op: "describeCertificates", method: "describe_certificates",
    input: { Limit: 10, SearchKey: "a b&c=d", ExpirationSort: "ASC" } },
  { id: "scf-invoke", product: "scf", op: "invoke", method: "invoke",
    input: { region: "ap-guangzhou", FunctionName: "hello", ClientContext: "{\"k\":\"v\",\"n\":[1,2.5,-0.125]}", Qualifier: "$LATEST" } },
  { id: "cls-search-log-numbers", product: "cls", op: "searchLog", method: "search_log",
    input: { region: "ap-guangzhou", From: 1700000000000, To: 1700003600000, Query: "status:500 AND \"x\"", Limit: 100, SamplingRate: 0.25, UseNewAnalysis: true } },
  { id: "undeclared-key-passes-through", product: "cvm", op: "describeInstances", method: "describe_instances",
    input: { Limit: 1, ZzExtra: { b: 2, a: [1, "x"] } } },
];

const requests = [];
for (const c of requestCases) {
  const { request } = await run(c);
  requests.push({ ...c, input: sortKeys(c.input), request });
}

// responses, all through one operation unless the case names another
const env = (inner) => JSON.stringify({ Response: inner });
const fail = (code, message, more = {}) =>
  env({ Error: { Code: code, Message: message }, RequestId: "req-2", ...more });
const responseCases = [
  { id: "ok", response: { body: env({ TotalCount: 1, InstanceSet: [{ InstanceId: "ins-1", CPU: 2, Tags: [] }], RequestId: "req-1" }) } },
  { id: "ok-empty-output", response: { body: env({ RequestId: "req-1" }) } },
  { id: "ok-extra-keys", response: { body: env({ TotalCount: 0, Surprise: { a: 1 }, RequestId: "req-1" }) } },
  { id: "ok-strict-extra-key", validation: "strict", response: { body: env({ TotalCount: 0, Surprise: 1, RequestId: "r" }) } },
  { id: "ok-strict-wrong-type", validation: "strict", response: { body: env({ TotalCount: "many", RequestId: "r" }) } },
  { id: "ok-additional", validation: "additional", response: { body: env({ TotalCount: 3, RequestId: "r" }) } },
  { id: "no-envelope-2xx", response: { body: JSON.stringify({ TotalCount: 1 }) } },
  { id: "response-not-object", response: { body: JSON.stringify({ Response: "x" }) } },
  { id: "response-array", response: { body: JSON.stringify([1, 2]) } },
  { id: "empty-body-200", response: { body: "" } },
  { id: "non-json-200", response: { body: "<html>ok</html>" } },
  { id: "error-without-message", response: { body: env({ Error: { Code: "AuthFailure.SecretIdNotFound" }, RequestId: "r9" }) } },
  { id: "error-without-code", response: { body: env({ Error: { Message: "who knows" }, RequestId: "r9" }) } },
  { id: "error-non-string-code", response: { body: env({ Error: { Code: 42, Message: "num" } }) } },
  { id: "error-without-request-id", response: { body: env({ Error: { Code: "InternalError", Message: "x" } }) } },
  { id: "error-on-http-400", response: { status: 400, body: fail("InvalidParameter.Format", "bad") } },
  { id: "error-on-http-500", response: { status: 500, body: fail("InternalError.DbError", "db") } },
  { id: "service-unavailable", response: { body: fail("ServiceUnavailable", "later") } },
  { id: "service-unavailable-detail", response: { body: fail("ServiceUnavailable.Busy", "later") } },
  { id: "product-code", response: { body: fail("InvalidInstanceId.NotFound", "no such instance") } },
  { id: "has-own-property-code", response: { body: fail("hasOwnProperty", "proto") } },
  { id: "toString-code", response: { body: fail("toString.x", "proto") } },
  { id: "http-502-html", response: { status: 502, body: "<html>bad gateway</html>" } },
  { id: "http-503-retry-after", response: { status: 503, body: "", headers: { "retry-after": "7" } } },
  { id: "http-429-retry-after", response: { status: 429, body: "{}", headers: { "retry-after": "3" } } },
  { id: "http-500-json-no-envelope", response: { status: 500, body: JSON.stringify({ message: "x" }) } },
  { id: "http-404-text", response: { status: 404, body: "not found" } },
  { id: "http-418-json", response: { status: 418, body: JSON.stringify({ tea: true }) } },
  { id: "http-418-text", response: { status: 418, body: "teapot " + "z".repeat(3000) } },
  { id: "http-599-empty", response: { status: 599, body: "" } },
  { id: "http-302", response: { status: 302, body: "", headers: { location: "https://x" } } },
];
for (const code of Object.keys(TC.COMMON_ERRORS)) {
  responseCases.push({ id: `common-${code}`, response: { body: fail(`${code}.Detail`, `msg ${code}`) } });
  responseCases.push({ id: `common-${code}-bare`, response: { body: fail(code, "") } });
}
const responses = [];
for (const c of responseCases) {
  const full = { product: "cvm", op: "describeInstances", method: "describe_instances", input: {}, ...c };
  const { outcome } = await run(full);
  responses.push({ ...full, outcome });
}

mkdirSync(path.dirname(out), { recursive: true });
writeFileSync(
  out,
  JSON.stringify(
    { epoch: EPOCH_MS / 1000, secret_id: SECRET_ID, secret_key: SECRET_KEY, session_token: SESSION_TOKEN, signer, requests, responses },
    null,
    1,
  ) + "\n",
);
console.log(`node: ${signer.length} signer vectors, ${requests.length} requests, ${responses.length} responses`);
