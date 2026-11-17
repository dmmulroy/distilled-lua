import fs from "node:fs";
const [pkg, ...svcs] = process.argv.slice(2);
const routes = new Set();
for (const f of fs.readdirSync(`models/${pkg}`)) { const m = JSON.parse(fs.readFileSync(`models/${pkg}/${f}`)); for (const s of Object.values(m.shapes)) { const h = s.traits && s.traits["smithy.api#http"]; if (s.type==="operation" && h) routes.add(h.method+" "+h.uri); } }
for (const svc of svcs) { const src = fs.readFileSync(`../distilled/packages/${pkg}/src/services/${svc}.ts`,"utf8");
  for (const h of src.matchAll(/T\.Http\(\{\s*method:\s*"(\w+)",\s*uri:\s*"([^"]+)"/g)) { const route = h[1]+" "+h[2];
    console.log(`| ${pkg} | ${svc} | \`${route}\` | ${routes.has(route) ? "in model" : "not in model"} |`); } }
