// Makes a model the generator refuses for reasons other tasks own generate anyway, for
// size and load measurements only (verify/lib/big_models.sh, task 18). Never used for a
// committed client.
//
//   node verify/lib/bench_sanitize.mjs <in.json> <out.json> [<generator errors.txt>]
//
// Always: drops the com.distilled.openapi#apiVersion trait and http apiVersion key (Azure,
// task 20), sets X-Ray telemetry propagation to w3c, drops error
// references whose target has no smithy.api#error trait, and gives an operation with no
// smithy.api#http trait the route POST /<Operation> (AWS, task 17). With an errors
// file (the generator's "generation failed" lines, `<shape id>: <problem>`): a pagination
// problem drops that operation's smithy.api#paginated trait, any other problem on an
// operation drops the operation. Prints what it changed as one JSON line on stdout.
import { readFileSync, writeFileSync } from "node:fs";

const [input, output, errorsFile] = process.argv.slice(2);
if (!input || !output) {
  console.error("usage: bench_sanitize.mjs <in.json> <out.json> [errors.txt]");
  process.exit(2);
}
const model = JSON.parse(readFileSync(input, "utf8"));
const shapes = model.shapes;
const changes = { apiVersion: 0, errorRefs: 0, http: 0, pagination: 0, droppedOps: [] };

const stripTrait = (traits) => {
  if (traits && "com.distilled.openapi#apiVersion" in traits) {
    delete traits["com.distilled.openapi#apiVersion"];
    changes.apiVersion++;
  }
};
const isError = (id) => shapes[id]?.traits?.["smithy.api#error"] !== undefined;

const ids = new Map(Object.entries(shapes).map(([id, s]) => [s, id]));
const op_name = (shape) => ids.get(shape)?.split("#")[1];
for (const shape of Object.values(shapes)) {
  stripTrait(shape.traits);
  for (const member of Object.values(shape.members ?? {})) stripTrait(member.traits);
  const http = shape.traits?.["smithy.api#http"];
  if (http && "apiVersion" in http) {
    delete http.apiVersion;
    changes.apiVersion++;
  }
  const tel = shape.traits?.["com.distilled.telemetry#service"];
  if (tel && tel.propagation && tel.propagation !== "w3c") {
    tel.propagation = "w3c"; // AWS X-Ray (task 17)
    changes.propagation = (changes.propagation ?? 0) + 1;
  }
  if (shape.type === "operation" && shape.traits?.["smithy.api#http"] === undefined) {
    // AWS query/JSON protocols bind no HTTP route: give each its own POST path, so the
    // shapes generate (the size is what is measured, not the route)
    shape.traits = shape.traits ?? {};
    shape.traits["smithy.api#http"] = { method: "POST", uri: "/" + (op_name(shape) ?? "op"), code: 200 };
    changes.http++;
  }
  if (Array.isArray(shape.errors)) {
    const kept = shape.errors.filter((e) => isError(e.target));
    changes.errorRefs += shape.errors.length - kept.length;
    shape.errors = kept;
  }
}

if (errorsFile) {
  const drop = new Set();
  for (const line of readFileSync(errorsFile, "utf8").split("\n")) {
    const m = /^(\S+#[A-Za-z0-9_]+): (.*)$/.exec(line.trim());
    if (!m || shapes[m[1]]?.type !== "operation") continue;
    const op = shapes[m[1]];
    if (/paginat/i.test(m[2]) && op.traits?.["smithy.api#paginated"] !== undefined) {
      delete op.traits["smithy.api#paginated"];
      changes.pagination++;
    } else {
      drop.add(m[1]);
    }
  }
  for (const shape of Object.values(shapes)) {
    if (shape.type === "service" && Array.isArray(shape.operations)) {
      shape.operations = shape.operations.filter((o) => !drop.has(o.target));
    }
  }
  for (const id of drop) delete shapes[id];
  changes.droppedOps = [...drop].sort();
}

writeFileSync(output, JSON.stringify(model));
console.log(JSON.stringify({ ...changes, droppedOps: changes.droppedOps.length }));
