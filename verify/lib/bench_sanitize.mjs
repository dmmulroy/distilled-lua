// Makes a model the generator refuses for reasons other tasks own generate anyway, for
// size and load measurements only (verify/lib/big_models.sh, task 18). Never used for a
// committed client.
//
//   node verify/lib/bench_sanitize.mjs <in.json> <out.json> [<generator errors.txt>]
//
// Always: drops the com.distilled.openapi#apiVersion trait (Azure, task 20) and error
// references whose target has no smithy.api#error trait (AWS, task 17). With an errors
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
const changes = { apiVersion: 0, errorRefs: 0, pagination: 0, droppedOps: [] };

const stripTrait = (traits) => {
  if (traits && "com.distilled.openapi#apiVersion" in traits) {
    delete traits["com.distilled.openapi#apiVersion"];
    changes.apiVersion++;
  }
};
const isError = (id) => shapes[id]?.traits?.["smithy.api#error"] !== undefined;

for (const shape of Object.values(shapes)) {
  stripTrait(shape.traits);
  for (const member of Object.values(shape.members ?? {})) stripTrait(member.traits);
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
