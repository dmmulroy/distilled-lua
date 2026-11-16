// dl conform, step 2b: what Distilled makes of each canned response.
//   node ... responses.mjs <provider>
// reads  verify/conform/cases/<provider>/responses.jsonl
// writes verify/conform/ref/<provider>/responses.jsonl
//   { id, ok: true, value } | { id, ok: false, error: { tag, categories, retryable, ... } }
// No retry (the Neon Retry service set to never), fixed credentials, a TestClock at
// 1700000000 s so an HTTP-date Retry-After is deterministic.
import * as path from "node:path";
import { Neon, ROOT, toInput, readLines, writeLines } from "./distilled.mjs";
import { creds, noRetry, outcomeOf, runVirtual, scripted, validationLayer } from "./outcome.mjs";

const provider = process.argv[2] ?? "neon";
const cases = readLines(path.join(ROOT, "verify/conform/cases", provider, "responses.jsonl"));
const out = [];
for (const c of cases) {
  const op = Neon[c.ts];
  const { layer } = scripted(() => c.response);
  const result = await runVirtual(
    op(toInput(c.input)),
    creds,
    noRetry,
    layer,
    validationLayer(c.validation),
  );
  out.push({ id: c.id, ...outcomeOf(result) });
}
writeLines(path.join(ROOT, "verify/conform/ref", provider, "responses.jsonl"), out);
console.log(`node: ${out.length} response outcomes from Distilled`);
