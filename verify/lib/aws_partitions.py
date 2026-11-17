#!/usr/bin/env python3
# Regenerates lua/distilled/aws/partitions.lua from Distilled's partitions.json.
#   python3 verify/lib/aws_partitions.py [../distilled/packages/s3/src/rules-engine/partitions.json]
import json, sys
src = sys.argv[1] if len(sys.argv) > 1 else "../distilled/packages/s3/src/rules-engine/partitions.json"
d = json.load(open(src))
def lv(v, ind=""):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, (int, float)): return repr(v)
    if isinstance(v, str): return json.dumps(v)
    if isinstance(v, list):
        if not v: return "{}"
        return "{\n" + "".join(ind + "  " + lv(x, ind + "  ") + ",\n" for x in v) + ind + "}"
    if not v: return "{}"
    out = "{\n"
    for k in sorted(v):
        key = k if k.isidentifier() else "[" + json.dumps(k) + "]"
        out += ind + "  " + key + " = " + lv(v[k], ind + "  ") + ",\n"
    return out + ind + "}"
parts = []
for p in d["partitions"]:
    regs = {k: {a: b for a, b in (v or {}).items() if a != "description"} for k, v in p["regions"].items()}
    parts.append({"id": p["id"], "regionRegex": p["regionRegex"], "outputs": p["outputs"], "regions": regs})
print("""-- AWS partition data for the endpoint rules' aws.partition function.
--
-- Generated from Distilled's packages/s3/src/rules-engine/partitions.json (version %s,
-- copied there from the AWS spec mirror by packages/aws/scripts/convert.ts). Region
-- descriptions are left out. Regenerate with verify/lib/aws_partitions.py.
return {
  version = %s,
  partitions = %s,
}""" % (d["version"], json.dumps(d["version"]), lv(parts, "  ")))
