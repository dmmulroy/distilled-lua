-- Prints the Cloudflare conformance report (compare.lua); exit 1 on a mismatch.
--   lua verify/conform/cloudflare/run.lua [root] [filter]     (MAX=n: mismatches shown)
local root = arg[1] or "."
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. package.path
local compare = require("verify.conform.cloudflare.compare")
local report = compare.run(root, { filter = arg[2] })
print(compare.format(report, tonumber(os.getenv("MAX") or "") or 20))
os.exit(#report.mismatches == 0 and 0 or 1)
