// dl conform, step 2a: the request Distilled builds for every case.
//   node ... requests.mjs <provider>
// reads  verify/conform/cases/<provider>/requests.jsonl
// writes verify/conform/ref/<provider>/requests.jsonl
//   { id, ok: true, method, url, headers, body: { kind, text?, b64?, parts? } }
//   { id, ok: false, error: { tag, message } }
// API.encodeRequest builds the request with the operation's protocol and does not send it.
import * as path from "node:path";
import { API, Effect, Neon, Redacted, ROOT, BASE_URL, API_KEY, toInput, readLines, writeLines, plain } from "./distilled.mjs";

const provider = process.argv[2] ?? "neon";
if (provider !== "neon") throw new Error(`no Distilled binding for provider ${provider}`);
const creds = Neon.fromApiKey({ apiKey: Redacted.make(API_KEY), apiBaseUrl: BASE_URL });

// bytes -> { text } when they are valid UTF-8 (readable dumps), else { b64 }
const bytesOf = (buf) => {
  const text = buf.toString("utf8");
  return Buffer.from(text, "utf8").equals(buf) ? { text } : { b64: buf.toString("base64") };
};

const bodyOf = async (body) => {
  switch (body._tag) {
    case "Empty":
      return { kind: "none" };
    case "Uint8Array":
      return {
        kind: "bytes",
        ...bytesOf(Buffer.from(body.body)),
        content_type: body.contentType,
      };
    case "Raw":
    case "Text":
      return { kind: "bytes", ...bytesOf(Buffer.from(String(body.body))), content_type: body.contentType };
    case "FormData": {
      const parts = [];
      for (const [name, value] of body.formData.entries()) {
        if (typeof value === "string") parts.push({ name, value });
        else
          parts.push({
            name,
            filename: value.name,
            content_type: value.type,
            ...bytesOf(Buffer.from(await value.arrayBuffer())),
          });
      }
      return { kind: "multipart", parts };
    }
    default:
      return { kind: "other", tag: body._tag };
  }
};

const cases = readLines(path.join(ROOT, "verify/conform/cases", provider, "requests.jsonl"));
const out = [];
let failed = 0;
for (const c of cases) {
  const op = Neon[c.ts];
  if (op === undefined) {
    out.push({ id: c.id, ok: false, error: { tag: "NoSuchOperation", message: c.ts } });
    failed++;
    continue;
  }
  const r = await Effect.runPromise(
    Effect.result(API.encodeRequest(op, toInput(c.input)).pipe(Effect.provide(creds))),
  );
  if (r._tag === "Success") {
    const req = r.success;
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = String(plain(v));
    out.push({ id: c.id, ok: true, method: req.method, url: req.url, headers, body: await bodyOf(req.body) });
  } else {
    const e = r.failure;
    out.push({ id: c.id, ok: false, error: { tag: e?._tag ?? String(e), message: e?.message } });
    failed++;
  }
}
writeLines(path.join(ROOT, "verify/conform/ref", provider, "requests.jsonl"), out);

// The top-level input members of every operation (names and optionality), so a member the
// Lua generator dropped or renamed shows up even though no case can send it.
const stateKey = Symbol.for("@distilled.cloud/core/api/OperationState");
const members = [];
for (const ts of [...new Set(cases.map((c) => c.ts))].sort()) {
  const op = Neon[ts];
  if (op === undefined) continue;
  let ast = op[stateKey]?.prepared?.inputAst;
  while (ast?._tag === "Suspend") ast = ast.thunk();
  const list = (ast?.propertySignatures ?? []).map((p) => ({
    name: String(p.name),
    required: !(p.type.context?.isOptional ?? false),
  }));
  members.push({ id: ts, op: cases.find((c) => c.ts === ts).op, members: list });
}
writeLines(path.join(ROOT, "verify/conform/ref", provider, "members.jsonl"), members);
console.log(`node: ${out.length} requests from Distilled (${failed} failed to build)`);
