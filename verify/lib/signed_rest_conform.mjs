// Writes spec/golden/signed_rest/conform.lua: what Distilled's Coinbase and Polymarket
// packages (packages/coinbase, packages/polymarket: the code clients/coinbase and
// clients/polymarket are generated to match) do with a sample of operations:
//   requests   the request API.encodeRequest builds (method, URL, every header, the
//              body; for Coinbase the JWT's header, claims and signature), or its error
//   responses  the outcome of a call over a stub HttpClient with a canned response
// spec/signed_rest_conform_spec.lua runs the same cases through the Lua clients.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/lib/signed_rest_conform.mjs spec/golden/signed_rest/conform.lua
//
// Pinned: Date.now (Coinbase nbf/exp) and the TestClock (Polymarket's timestamp) at
// EPOCH_MS; crypto.randomBytes (Coinbase's nonce) returns NONCE_BYTES; retries are off.
// ES256 signatures from node:crypto are randomized, so for them only the JWT's first two
// segments are compared and the signature is verified (here and in the spec).
import * as path from "node:path";
import * as nodeCrypto from "node:crypto";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const out = process.argv[2];
if (!out) throw new Error("usage: signed_rest_conform.mjs <out.lua>");

const EPOCH_MS = 1700000000000;
const RealDate = Date;
globalThis.Date = class extends RealDate {
  constructor(...a) {
    if (a.length === 0) super(EPOCH_MS);
    else super(...a);
  }
  static now() {
    return EPOCH_MS;
  }
};
const NONCE_BYTES = Array.from({ length: 16 }, (_, i) => (i * 37 + 11) % 256);
const cjsCrypto = createRequire(import.meta.url)("node:crypto");
cjsCrypto.randomBytes = (n) => Buffer.from(NONCE_BYTES.slice(0, n));
syncBuiltinESMExports();

const API = await import(path.join(P, "core/src/api.ts"));
const Category = await import(path.join(P, "core/src/category.ts"));
const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Duration = await import(E + "Duration.js");
const Fiber = await import(E + "Fiber.js");
const TestClock = await import(E + "testing/TestClock.js");
const HttpClient = await import(E + "http/HttpClient.js");
const HttpClientResponse = await import(E + "http/HttpClientResponse.js");

const CB = {
  ops: await import(path.join(P, "coinbase/src/services/cdp.ts")),
  creds: await import(path.join(P, "coinbase/src/credentials.ts")),
  retry: await import(path.join(P, "coinbase/src/retry.ts")),
};
const PM = {
  signing: await import(path.join(P, "polymarket/src/signing.ts")),
  creds: await import(path.join(P, "polymarket/src/credentials.ts")),
  retry: await import(path.join(P, "polymarket/src/retry.ts")),
  services: {},
};
for (const m of ["clob", "combos-rfq", "gamma", "data", "relayer", "bridge", "perps"]) {
  PM.services[m.replace("-", "_")] = await import(path.join(P, `polymarket/src/services/${m}.ts`));
}

// ---------------------------------------------------------------------------------------
// keys
// ---------------------------------------------------------------------------------------

const pkKeys = JSON.parse(readFileSync(path.join(ROOT, "spec/golden/crypto_pk/keys.json"), "utf8"));
const EC_PEM = pkKeys.p256.sec1;
const EC_SPKI = pkKeys.p256.spki;
const ED_SEED = Buffer.from(Array.from({ length: 32 }, (_, i) => (i * 7 + 3) % 256));
const edKey = nodeCrypto.createPrivateKey({
  key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), ED_SEED]),
  format: "der",
  type: "pkcs8",
});
const ED_PUBLIC = nodeCrypto.createPublicKey(edKey).export({ format: "der", type: "spki" }).subarray(-32);
const ED_SECRET = Buffer.concat([ED_SEED, ED_PUBLIC]).toString("base64");
const ED_PEM = edKey.export({ format: "pem", type: "pkcs8" });
const RSA_PEM = pkKeys.rsa2048.pkcs8;
const KEY_ID = "organizations/org-id/apiKeys/key-id";

const CLOB = {
  address: "0x1111111111111111111111111111111111111111",
  apiKey: "7b1e2d60-6f9a-4dd7-8f3e-21b8f94c77a2",
  secret: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  passphrase: "passphrase-value",
};
const RELAYER = { address: "0x2222222222222222222222222222222222222222", apiKey: "relayer-key-value" };
const PERPS = { proxy: "0x3333333333333333333333333333333333333333", secret: "perps-secret-value" };

// ---------------------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------------------

const plain = (v) => (Redacted.isRedacted(v) ? Redacted.value(v) : v);

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
  if (e === null || typeof e !== "object") return { tag: String(e) };
  const fields = {};
  for (const [k, x] of Object.entries(e)) {
    if (k.startsWith("_") || typeof x === "function" || x === undefined) continue;
    if (["message", "body", "headers", "cause", "stack", "retryAfter"].includes(k)) continue;
    fields[k] = view(x);
  }
  const r = e[Category.retryableKey];
  return {
    tag: e._tag ?? e.constructor?.name,
    categories: Object.keys(e[Category.categoriesKey] ?? {}).sort(),
    retryable: r !== undefined,
    message: typeof e.message === "string" ? e.message : undefined,
    fields,
  };
};

const runAt = (effect, layer) =>
  Effect.runPromise(
    Effect.gen(function* () {
      yield* TestClock.setTime(EPOCH_MS);
      const fiber = yield* Effect.forkChild(Effect.result(effect));
      yield* TestClock.adjust(Duration.hours(1));
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(layer)),
  );

const stub = (reply, sent) =>
  Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.sync(() => {
        sent.push({ method: request.method, url: request.url });
        const nullBody = reply.status === 204 || reply.status === 304;
        return HttpClientResponse.fromWeb(
          request,
          new Response(nullBody ? null : Buffer.from(reply.body ?? "", "utf8"), {
            status: reply.status,
            headers: reply.headers ?? {},
          }),
        );
      }),
    ),
  );

const bodyOf = (body) => {
  switch (body._tag) {
    case "Empty":
      return null;
    case "Uint8Array":
      return Buffer.from(body.body).toString("utf8");
    case "Raw":
    case "Text":
      return String(body.body);
    default:
      return { other: body._tag };
  }
};

const requestView = (req) => {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(plain(v));
  return { method: req.method, url: req.url, headers, body: bodyOf(req.body) };
};

const camel = (s) => s[0].toLowerCase() + s.slice(1);
const snake = (s) =>
  s
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .toLowerCase();

// ---------------------------------------------------------------------------------------
// Coinbase
// ---------------------------------------------------------------------------------------

const coinbaseLayer = (c) =>
  Layer.mergeAll(
    Layer.succeed(
      CB.creds.Credentials,
      Effect.succeed({
        apiKeyId: c.key_id ?? KEY_ID,
        apiKeySecret: Redacted.make(c.secret),
        apiBaseUrl: c.base_url ?? CB.creds.DEFAULT_API_BASE_URL,
      }),
    ),
    TestClock.layer(),
    Layer.succeed(CB.retry.Retry, { while: () => false }),
  );

const SECRETS = { ed25519: ED_SECRET, es256: EC_PEM, ed25519_pem: ED_PEM, rsa_pem: RSA_PEM };

const jwtView = (authorization, key) => {
  const token = authorization.replace(/^Bearer /, "");
  const [h, p, s] = token.split(".");
  const header = JSON.parse(Buffer.from(h, "base64url").toString("utf8"));
  let verified;
  if (header.alg === "ES256") {
    verified = nodeCrypto.verify("sha256", Buffer.from(`${h}.${p}`), { key: EC_SPKI, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url"));
  } else {
    verified = nodeCrypto.verify(null, Buffer.from(`${h}.${p}`), nodeCrypto.createPublicKey(edKey), Buffer.from(s, "base64url"));
  }
  if (!verified) throw new Error("Distilled's JWT does not verify");
  return { alg: header.alg, protected: h, payload: p, signature: header.alg === "EdDSA" ? s : undefined };
};

const coinbaseRequests = [
  { id: "list-evm-accounts-eddsa", op: "ListEvmAccounts", input: { pageSize: 10, pageToken: "a b/c" }, key: "ed25519" },
  { id: "get-evm-account-eddsa", op: "GetEvmAccount", input: { address: "0xAbC/../d e" }, key: "ed25519" },
  { id: "create-evm-account-eddsa", op: "CreateEvmAccount", input: { name: "my-account", accountPolicy: "p1" }, key: "ed25519" },
  { id: "list-evm-accounts-es256", op: "ListEvmAccounts", input: {}, key: "es256" },
  { id: "create-evm-account-es256", op: "CreateEvmAccount", input: { name: "n" }, key: "es256" },
  { id: "custom-base-port", op: "ListEvmAccounts", input: {}, key: "ed25519", base_url: "http://LOCALHOST:8080/platform" },
  { id: "default-port-dropped", op: "ListEvmAccounts", input: {}, key: "ed25519", base_url: "https://api.cdp.coinbase.com:443/platform" },
  { id: "uuid-key-id", op: "ListEvmAccounts", input: {}, key: "ed25519", key_id: "6f0b8a4e-5e7c-4a5e-9d1e-2c3b4a5d6e7f" },
  { id: "ed25519-pem-cannot-sign-es256", op: "ListEvmAccounts", input: {}, key: "ed25519_pem" },
  { id: "unsupported-secret", op: "ListEvmAccounts", input: {}, secret: "not-a-key" },
  { id: "bad-pem", op: "ListEvmAccounts", input: {}, secret: "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n" },
  { id: "relative-base-url", op: "ListEvmAccounts", input: {}, key: "ed25519", base_url: "/platform" },
];

const coinbaseResponses = [
  { id: "ok", op: "ListEvmAccounts", reply: { status: 200, body: '{"accounts":[{"address":"0x1","name":"a"}],"nextPageToken":"t"}' } },
  ...[
    ["already-exists", 409, "already_exists"],
    ["idempotency", 422, "idempotency_error"],
    ["faucet-limit", 429, "faucet_limit_exceeded"],
    ["timed-out", 504, "timed_out"],
    ["account-not-ready", 400, "account_not_ready"],
    ["payment-method-required", 402, "payment_method_required"],
    ["settlement-failed", 500, "settlement_failed"],
    ["mfa-required", 401, "mfa_required"],
    ["source-account-not-found", 404, "source_account_not_found"],
    ["order-already-filled", 409, "order_already_filled"],
    ["standard-not-found", 404, "not_found"],
    ["standard-invalid-request", 400, "invalid_request"],
    ["standard-rate-limit", 429, "rate_limit_exceeded"],
    ["standard-unauthorized", 401, "unauthorized"],
    ["standard-internal", 500, "internal_server_error"],
    ["unknown-type-mapped-status", 403, "some_new_type"],
    ["unknown-type-unmapped-status", 418, "some_new_type"],
    ["unknown-type-402", 402, "some_new_type"],
  ].map(([id, status, type]) => ({
    id: "error-" + id,
    op: "GetEvmAccount",
    input: { address: "0x1" },
    reply: {
      status,
      body: JSON.stringify({ errorType: type, errorMessage: `msg ${type}`, correlationId: "corr-1", errorLink: "https://docs.cdp.coinbase.com/x" }),
      headers: { "retry-after": "7" },
    },
  })),
  { id: "error-envelope-no-link", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 409, body: '{"errorType":"already_exists","errorMessage":"dup"}' } },
  { id: "error-html-404", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 404, body: "<html>not found</html>" } },
  { id: "error-html-418", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 418, body: "<html>teapot</html>" } },
  { id: "error-empty-599", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 599, body: "" } },
  { id: "error-text-599", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 599, body: "upstream down" } },
  { id: "error-empty-402", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 402, body: "" } },
  { id: "error-long-text-400", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 400, body: "x".repeat(250) } },
  { id: "error-bad-envelope-types", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 409, body: '{"errorType":1,"errorMessage":"m"}' } },
  { id: "failure-is-valid", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 400, body: '{"isValid":false,"address":"0x9"}' } },
  { id: "failure-success-key", op: "GetEvmAccount", input: { address: "0x1" }, reply: { status: 422, body: '{"success":false}' } },
];

const result = {
  epoch: EPOCH_MS / 1000,
  nonce_bytes: NONCE_BYTES,
  coinbase: { key_id: KEY_ID, secrets: SECRETS, ec_spki: EC_SPKI, requests: [], responses: [] },
  polymarket: { clob: CLOB, relayer: RELAYER, perps: PERPS, requests: [], responses: [] },
};

for (const c of coinbaseRequests) {
  const secret = c.secret ?? SECRETS[c.key];
  const r = await runAt(API.encodeRequest(CB.ops[camel(c.op)], c.input), coinbaseLayer({ ...c, secret }));
  const entry = { id: c.id, op: snake(c.op), input: c.input, key: c.key, secret: c.secret, base_url: c.base_url, key_id: c.key_id };
  if (r._tag === "Success") {
    const req = requestView(r.success);
    const jwt = jwtView(req.headers.authorization);
    delete req.headers.authorization;
    entry.expected = { ok: true, request: req, jwt };
  } else {
    entry.expected = { ok: false, error: errorView(r.failure) };
  }
  result.coinbase.requests.push(entry);
}

for (const c of coinbaseResponses) {
  const sent = [];
  const r = await runAt(CB.ops[camel(c.op)](c.input ?? {}), Layer.mergeAll(coinbaseLayer({ secret: ED_SECRET }), stub(c.reply, sent)));
  result.coinbase.responses.push({
    id: c.id,
    op: snake(c.op),
    input: c.input ?? {},
    reply: c.reply,
    expected: r._tag === "Success" ? { ok: true, value: view(r.success) ?? null } : { ok: false, error: errorView(r.failure) },
  });
}

// ---------------------------------------------------------------------------------------
// Polymarket
// ---------------------------------------------------------------------------------------

const polymarketLayer = (c) => {
  const config = {};
  if (c.clob) config.clob = { address: CLOB.address, apiKey: Redacted.make(CLOB.apiKey), secret: Redacted.make(c.clob_secret ?? CLOB.secret), passphrase: Redacted.make(CLOB.passphrase) };
  if (c.relayer) config.relayer = { address: RELAYER.address, apiKey: Redacted.make(RELAYER.apiKey) };
  if (c.perps) config.perps = { proxy: PERPS.proxy, secret: Redacted.make(PERPS.secret) };
  if (c.base_urls) config.baseUrls = c.base_urls;
  return Layer.mergeAll(PM.creds.credentials(config), TestClock.layer(), Layer.succeed(PM.retry.Retry, { while: () => false }));
};

const polymarketRequests = [
  { id: "clob-get-orders-signed", model: "clob", op: "GetOrders", input: { market: "0xabc", next_cursor: "MA==" }, clob: true },
  { id: "clob-get-orders-unsigned", model: "clob", op: "GetOrders", input: { market: "0xabc" } },
  { id: "clob-get-book-signed", model: "clob", op: "GetBook", input: { token_id: "123" }, clob: true },
  { id: "clob-cancel-order-body", model: "clob", op: "CancelOrder", input: { orderID: "0xdeadbeef" }, clob: true },
  { id: "clob-cancel-orders-list-body", model: "clob", op: "CancelOrders", input: { body: ["0xa", "0xb"] }, clob: true },
  { id: "clob-create-api-key-l2", model: "clob", op: "CreateApiKey", input: {}, clob: true },
  { id: "clob-base-url-path", model: "clob", op: "GetOrders", input: {}, clob: true, base_urls: { clob: "http://localhost:9000/proxy/" } },
  { id: "clob-urlsafe-secret", model: "clob", op: "GetOrders", input: {}, clob: true, clob_secret: "--_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
  { id: "combos-cancel-quote-signed", model: "combos_rfq", op: "CancelMakerQuote", input: { rfq_id: "r1", quote_id: "q1", signer_address: "0x1", maker_address: "0x2", signature_type: 0 }, clob: true },
  { id: "combos-get-markets-unsigned", model: "combos_rfq", op: "GetComboMarkets", input: {} },
  { id: "relayer-nonce-keyed", model: "relayer", op: "GetNonce", input: { address: "0x4", type: "PROXY" }, relayer: true, clob: true },
  { id: "relayer-nonce-public", model: "relayer", op: "GetNonce", input: { address: "0x4", type: "SAFE" } },
  { id: "perps-cancel-orders", model: "perps", op: "CancelOrders", input: { op: { type: "cancel", ids: [1] }, sig: "0x", salt: 1, ts: 2 }, perps: true },
  { id: "gamma-list-markets", model: "gamma", op: "ListMarkets", input: { limit: 5, closed: false }, clob: true },
];

const polymarketResponses = [
  { id: "ok", model: "clob", op: "GetOrders", input: {}, reply: { status: 200, body: '{"data":[],"next_cursor":"LTE="}' } },
  { id: "payload-too-large", model: "perps", op: "CancelOrders", input: { op: { type: "cancel" }, sig: "0x", salt: 1, ts: 2 }, reply: { status: 413, body: '{"error":"payload_too_large"}' } },
  { id: "not-found-error-text", model: "clob", op: "GetOrders", input: {}, reply: { status: 404, body: '{"error":"market not found"}' } },
  { id: "unauthorized", model: "clob", op: "GetOrders", input: {}, reply: { status: 401, body: '{"error":"Unauthorized/Invalid api key"}' } },
  { id: "unknown-with-code", model: "data", op: "GetPositions", input: { user: "0x1" }, reply: { status: 418, body: '{"error":"odd","code":"E_ODD"}' } },
  { id: "too-many-requests", model: "gamma", op: "ListMarkets", input: {}, reply: { status: 429, body: '{"error":"slow down"}', headers: { "retry-after": "3" } } },
];

// JSON.stringify with every object's keys sorted: how distilled.json writes a body
const sortedJson = (v) =>
  JSON.stringify(v, (_, x) =>
    x && typeof x === "object" && !Array.isArray(x)
      ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]]))
      : x,
  );

// Distilled's signL2 over the body as the Lua client writes it (sorted keys), when that
// differs from Distilled's own body: the L2 signature covers the exact bytes sent
const sortedSignature = async (c, req) => {
  if (!c.clob || typeof req.body !== "string" || !req.headers.poly_signature) return undefined;
  const sorted = sortedJson(JSON.parse(req.body));
  if (sorted === req.body) return undefined;
  const base = (c.base_urls?.[c.model] ?? PM.creds.DEFAULT_BASE_URLS[c.model === "combos_rfq" ? "combosRfq" : c.model]).replace(/\/+$/, "");
  const below = req.url.startsWith(base) ? req.url.slice(base.length) : req.url;
  const p = below.split(/[?#]/, 1)[0];
  const signature = await Effect.runPromise(
    PM.signing.signL2({
      secret: c.clob_secret ?? CLOB.secret,
      timestamp: EPOCH_MS / 1000,
      method: req.method,
      requestPath: p.startsWith("/") ? p : `/${p}`,
      body: sorted,
    }),
  );
  return { body: sorted, poly_signature: signature };
};

for (const c of polymarketRequests) {
  const op = PM.services[c.model][camel(c.op)];
  if (!op) throw new Error(`no Polymarket ${c.model} operation ${c.op}`);
  const r = await runAt(API.encodeRequest(op, c.input), polymarketLayer(c));
  const request = r._tag === "Success" ? requestView(r.success) : undefined;
  result.polymarket.requests.push({
    id: c.id,
    model: c.model,
    op: snake(c.op),
    input: c.input,
    clob: c.clob,
    relayer: c.relayer,
    perps: c.perps,
    clob_secret: c.clob_secret,
    base_urls: c.base_urls,
    expected: request ? { ok: true, request, sorted_body: await sortedSignature(c, request) } : { ok: false, error: errorView(r.failure) },
  });
}

for (const c of polymarketResponses) {
  const op = PM.services[c.model][camel(c.op)];
  if (!op) throw new Error(`no Polymarket ${c.model} operation ${c.op}`);
  const sent = [];
  const r = await runAt(op(c.input), Layer.mergeAll(polymarketLayer(c), stub(c.reply, sent)));
  result.polymarket.responses.push({
    id: c.id,
    model: c.model,
    op: snake(c.op),
    input: c.input,
    reply: c.reply,
    expected: r._tag === "Success" ? { ok: true, value: view(r.success) ?? null } : { ok: false, error: errorView(r.failure) },
  });
}

// ---------------------------------------------------------------------------------------
// output
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
  "-- Generated by verify/lib/signed_rest_conform.mjs from Distilled's packages/coinbase and\n" +
    "-- packages/polymarket. Do not edit. Arrays are Lua lists (an empty one is `{ n = 0 }`).\nreturn " +
    lua(result) +
    "\n",
);
console.log(
  `wrote ${out}: coinbase ${result.coinbase.requests.length} requests, ${result.coinbase.responses.length} responses; ` +
    `polymarket ${result.polymarket.requests.length} requests, ${result.polymarket.responses.length} responses`,
);
