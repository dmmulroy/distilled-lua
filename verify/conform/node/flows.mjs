// dl conform, step 2c: scripted multi-response flows (retry loops, pagination) through
// Distilled. A TestClock at 1700000000 s, Math.random pinned to 0.5 (outcome.mjs), and a
// fresh default retry budget per case.
//   writes verify/conform/ref/<provider>/flows.jsonl
//   { id, requests: [{ method, url, at_ms }], result: { ok, value | error } }
// `items` / `pages` results: { ok, value: [...] } on success; on failure the error plus
// `partial`, what the traversal produced before it failed.
import * as path from "node:path";
import { Effect, Layer, Neon, Stream, ROOT, toInput, readLines, writeLines } from "./distilled.mjs";
import { EPOCH_MS, creds, noRetry, outcomeOf, runVirtual, scripted, view, errorView, RetryCore } from "./outcome.mjs";

const provider = process.argv[2] ?? "neon";
const cases = readLines(path.join(ROOT, "verify/conform/cases", provider, "flows.jsonl"));

const retryLayer = (name) => {
  switch (name) {
    case "none":
      return noRetry;
    case "throttling":
      return Layer.succeed(Neon.Retry.Retry, RetryCore.throttlingFactory);
    case "transient":
      return Layer.succeed(Neon.Retry.Retry, RetryCore.transientFactory);
    default:
      return Layer.empty;
  }
};

const out = [];
for (const c of cases) {
  RetryCore.defaultBudget.reset();
  if (process.env.DL_CONFORM_DEBUG) console.error(c.id);
  const { sent, layer } = scripted((n) => {
    if (n < c.script.length) return c.script[n];
    return c.forever ?? "transport";
  });
  const op = Neon[c.ts];
  const input = toInput(c.input);
  let result;
  if (c.kind === "call") {
    result = outcomeOf(await runVirtual(op(input), creds, layer, retryLayer(c.retry)));
  } else {
    const got = [];
    const stream = c.kind === "items" ? op.items(input) : op.pages(input);
    const r = await runVirtual(
      Stream.runForEach(stream, (x) => Effect.sync(() => got.push(view(x)))),
      creds,
      layer,
      retryLayer(c.retry),
    );
    result =
      r._tag === "Success"
        ? { ok: true, value: got }
        : { ok: false, error: errorView(r.failure), partial: got };
  }
  out.push({
    id: c.id,
    requests: sent.map((s) => ({ method: s.method, url: s.url, at_ms: Math.round(s.at - EPOCH_MS) })),
    result,
  });
}
writeLines(path.join(ROOT, "verify/conform/ref", provider, "flows.jsonl"), out);
console.log(`node: ${out.length} flows through Distilled`);
