// GraphQL request conformance (task 16): the requests Distilled's generated GraphQL SDKs
// send for the plans in spec/fixtures/graphql/cases.json, recorded for
// spec/graphql_conform_spec.lua (which builds the same plans with the Lua clients and
// compares query text, variables and operationName). Output: { [case id]: { requests:
// [{ query, variables, operationName }], error?: { tag, message } } }.
//
//   node --conditions=bun --experimental-transform-types --no-warnings \
//     verify/conform/node/graphql_requests.mjs > spec/golden/graphql/requests.json
//
// The case language (shared with the Lua spec):
//   { "q": [step, ...] }     a Query: { "root": name, "args": {...} } or { "item": true }
//                            first, then "field", { "f": name, "args": {...} },
//                            { "map": plan } or { "filter": plan }
//   { "obj": { k: plan } }   a table;   { "lit": v }  a plain value;   { "of": v }  Query.of
//   { "$secret": "v" }       a secret argument value
// Two Lua rules are applied here so both sides build the same document: a plan's keys
// are visited sorted, and arguments are passed in the schema's declaration order (the
// order of the field's argTypes).
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(here, "../../..");
const DISTILLED = process.env.DISTILLED_ROOT ?? path.resolve(ROOT, "../distilled");
const P = path.join(DISTILLED, "packages");
const E = path.join(P, "core/node_modules/effect/dist") + "/";

const Effect = await import(E + "Effect.js");
const Layer = await import(E + "Layer.js");
const Redacted = await import(E + "Redacted.js");
const Stream = await import(E + "Stream.js");
const { GqlTransport } = await import(path.join(P, "core/src/graphql.ts"));
const { Query } = await import(path.join(P, "core/src/query.ts"));

const SDKS = {
  linear: (await import(path.join(P, "linear/src/graphql.ts"))).Linear,
  railway: (await import(path.join(P, "railway/src/graphql.ts"))).Railway,
  expo_eas: (await import(path.join(P, "expo-eas/src/graphql.ts"))).Eas,
  github: (await import(path.join(P, "github/src/graphql.ts"))).GitHub,
  fly_io: (await import(path.join(P, "fly-io/src/graphql.ts"))).Fly,
};

const value = (v) => {
  if (v === null || typeof v !== "object") return v;
  if (Array.isArray(v)) return v.map(value);
  const keys = Object.keys(v);
  if (keys.length === 1 && keys[0] === "$secret") return Redacted.make(v.$secret);
  const out = {};
  for (const k of keys) out[k] = value(v[k]);
  return out;
};

// arguments in the order of argTypes (declaration order), as the Lua client binds them
const ordered = (args, argTypes) => {
  const out = {};
  for (const name of Object.keys(argTypes ?? {})) if (name in args) out[name] = value(args[name]);
  for (const name of Object.keys(args).sort()) if (!(name in out)) out[name] = value(args[name]);
  return out;
};

const build = (sdk, node, item) => {
  if (node === null || typeof node !== "object") return node;
  if ("lit" in node) return node.lit;
  if ("of" in node) return Query.of(node.of);
  if ("obj" in node) {
    const out = {};
    for (const k of Object.keys(node.obj).sort()) out[k] = build(sdk, node.obj[k], item);
    return out;
  }
  if ("q" in node) {
    const [first, ...steps] = node.q;
    let q;
    if (first.item) q = item;
    else {
      const make = sdk[first.root];
      if (!make) throw new Error(`no root ${first.root}`);
      q = first.args ? make(ordered(first.args, make().expr.argTypes)) : make();
    }
    for (const step of steps) {
      if (typeof step === "string") q = q[step];
      else if (step.f) {
        const prop = q[step.f];
        q = prop(ordered(step.args ?? {}, prop.expr.field.argTypes));
      } else if (step.map) {
        const body = step.map;
        q = Query.map((it) => build(sdk, body, it))(q);
      } else if (step.filter) {
        const body = step.filter;
        q = Query.filter((it) => build(sdk, body, it))(q);
      } else throw new Error(`bad step ${JSON.stringify(step)}`);
      if (q === undefined) throw new Error(`undefined after ${JSON.stringify(step)}`);
    }
    return q;
  }
  throw new Error(`bad node ${JSON.stringify(node)}`);
};

const cases = JSON.parse(fs.readFileSync(path.join(ROOT, "spec/fixtures/graphql/cases.json"), "utf8"));
const out = {};
for (const c of cases) {
  const sdk = SDKS[c.sdk];
  const requests = [];
  // where the page's connection sits in the response (default: the root field)
  const pagePath = c.pages ? (c.page_path ?? [c.pages.q[0].root]) : undefined;
  const layer = Layer.succeed(GqlTransport, {
    execute: (request) =>
      Effect.sync(() => {
        requests.push({
          query: request.document,
          variables: request.variables,
          operationName: request.operationName,
        });
        if (pagePath === undefined) return { data: {} };
        const more = requests.length === 1;
        let data = { edges: [], pageInfo: { hasNextPage: more, endCursor: more ? "c1" : null } };
        for (const key of [...pagePath].reverse()) data = { [key]: data };
        return { data };
      }),
  });
  const program = c.pages
    ? Stream.runCollect(Query.pages(build(sdk, c.pages)))
    : Query.fn(() => build(sdk, c.plan))();
  try {
    await Effect.runPromise(program.pipe(Effect.provide(layer)));
    out[c.id] = { requests };
  } catch (e) {
    // a plan the compiler refuses: the Lua client must refuse it with the same message
    out[c.id] = { requests, error: { tag: e._tag ?? "Error", message: e.message } };
  }
}
process.stdout.write(JSON.stringify(out, null, 1) + "\n");
