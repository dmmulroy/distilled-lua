// Shared by responses.mjs and flows.mjs: the stub HttpClient, the fixed environment and
// the outcome record both sides produce.
import * as path from "node:path";
import {
  API, Category, Duration, Effect, HttpClient, HttpClientError, HttpClientResponse, Layer, Neon,
  Redacted, TestClock, Clock, Fiber, BASE_URL, API_KEY, DISTILLED,
} from "./distilled.mjs";

const RV = await import(path.join(DISTILLED, "packages/core/src/response-validation.ts"));
const RetryCore = await import(path.join(DISTILLED, "packages/core/src/retry.ts"));

export const EPOCH_MS = 1700000000000;

// Distilled reads wall time with Date.now() in retry-after.ts (an HTTP-date Retry-After is
// "date - Date.now()"), not the Effect Clock. Pin it: it follows the TestClock time of the
// latest request, so it equals the Lua fake clock (testing.host epoch) at that moment.
// Jitter is pinned too (Math.random = 0.5), as Distilled's own retry tests do.
const clockState = { nowMs: EPOCH_MS };
Date.now = () => clockState.nowMs;
Math.random = () => 0.5;
export const creds = Neon.fromApiKey({ apiKey: Redacted.make(API_KEY), apiBaseUrl: BASE_URL });
export const noRetry = Layer.succeed(Neon.Retry.Retry, { while: () => false });

export const validationLayer = (mode) =>
  mode === "strict" ? RV.strict : mode === "additional" ? RV.additionalProperties : RV.lenient;

const bodyBytes = (r) =>
  r.body_b64 !== undefined ? Buffer.from(r.body_b64, "base64") : r.body !== undefined ? Buffer.from(r.body, "utf8") : null;

/** A web Response from a case's canned response. A null-body status gets no body. */
export const webResponse = (r) => {
  const status = r.status ?? 200;
  const nullBody = status === 204 || status === 205 || status === 304;
  return new Response(nullBody ? null : bodyBytes(r), { status, headers: r.headers ?? {} });
};

/**
 * A stub HttpClient replying from `script(n, request)` (n is 0-based); a reply is a canned
 * response or "transport" for a transport failure. Records each request and the clock.
 */
export const scripted = (script) => {
  const sent = [];
  const layer = Layer.succeed(
    HttpClient.HttpClient,
    HttpClient.make((request) =>
      Effect.gen(function* () {
        const at = yield* Clock.currentTimeMillis;
        clockState.nowMs = at;
        const n = sent.length;
        sent.push({ method: request.method, url: request.url, at });
        const reply = script(n, request);
        if (reply === undefined || reply === "transport") {
          return yield* Effect.fail(
            new HttpClientError.HttpClientError({
              reason: new HttpClientError.TransportError({ request, description: "reset" }),
            }),
          );
        }
        return HttpClientResponse.fromWeb(request, webResponse(reply));
      }),
    ),
  );
  return { sent, layer };
};

/** JSON-able view of a decoded value: Redacted -> { $redacted: value }, bytes -> { $bytes_b64 }. */
export const view = (v) => {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object") return v;
  if (Redacted.isRedacted(v)) return { $redacted: view(Redacted.value(v)) };
  if (v instanceof Uint8Array) return { $bytes_b64: Buffer.from(v).toString("base64") };
  if (Array.isArray(v)) return v.map(view);
  const out = {};
  for (const [k, x] of Object.entries(v)) if (x !== undefined) out[k] = view(x);
  return out;
};

export const errorView = (e) => {
  if (e === null || typeof e !== "object") return { tag: String(e) };
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
    retry_after: ra === undefined ? undefined : Duration.toMillis(ra) / 1000,
    body: view(e.body),
  };
};

/** Run `effect` with the layers under a TestClock at EPOCH_MS, advancing an hour of virtual time. */
export const runVirtual = (effect, ...layers) =>
  Effect.runPromise(
    Effect.gen(function* () {
      clockState.nowMs = EPOCH_MS;
      yield* TestClock.setTime(EPOCH_MS);
      const fiber = yield* Effect.forkChild(Effect.result(effect));
      yield* TestClock.adjust(Duration.hours(1));
      return yield* Fiber.join(fiber);
    }).pipe(Effect.provide(Layer.mergeAll(TestClock.layer(), ...layers))),
  );

export const outcomeOf = (result) =>
  result._tag === "Success"
    ? { ok: true, value: view(result.success) ?? null }
    : { ok: false, error: errorView(result.failure) };

export { RetryCore };
