// Writes spec/fixtures/xml/<name>.expected.json for every <name>.xml there: Distilled's
// parseXmlSync result, keys sorted by UTF-8 bytes (what distilled.json emits), so
// spec/xml_spec.lua can compare without Node. Rerun after adding or changing a fixture:
//   node --conditions=bun --experimental-transform-types verify/lib/xml_fixtures.mjs \
//     ../distilled/packages/core/src/xml.ts spec/fixtures/xml
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [xmlTs, dir] = process.argv.slice(2);
const { parseXmlSync } = await import(pathToFileURL(resolve(xmlTs)).href);
const byUtf8 = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const canonical = (v) =>
  typeof v === "string"
    ? JSON.stringify(v)
    : Array.isArray(v)
      ? `[${v.map(canonical).join(",")}]`
      : `{${Object.keys(v).sort(byUtf8).map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
for (const f of readdirSync(dir).sort()) {
  if (!f.endsWith(".xml")) continue;
  const out = join(dir, f.replace(/\.xml$/, ".expected.json"));
  writeFileSync(out, canonical(parseXmlSync(readFileSync(join(dir, f), "utf8"))) + "\n");
  console.log(`wrote ${out}`);
}
