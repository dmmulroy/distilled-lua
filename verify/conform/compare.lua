-- dl conform, step 3: run the Lua side of every case and diff it against Distilled's
-- saved reference (verify/conform/ref/<provider>/). Runs under lua, luajit and Rex.
--
--   lua verify/conform/compare.lua <root> <provider> [categories]
--   rex do verify/conform/compare.lua root=<root> provider=<provider> [only=<categories>]
--
-- categories: comma-separated subset of requests,responses,flows (default all).
-- Prints a summary per category and a field-level diff per mismatch; exits non-zero
-- (raises, in Rex) on any mismatch that is not an intended difference.
local rex_api = rawget(_G, "rex")
local args = {}
if rex_api then
  local a = rawget(rex_api, "args") or {}
  args.root, args.provider, args.only, args.verbose = a.root, a.provider, a.only, a.verbose
else
  args.root, args.provider, args.only = arg[1], arg[2], arg[3]
  args.verbose = os.getenv("DL_CONFORM_VERBOSE")
end
assert(args.root and args.provider, "usage: compare.lua <root> <provider> [categories]")
local root = args.root
package.path = root
  .. "/lua/?.lua;"
  .. root
  .. "/lua/?/init.lua;"
  .. root
  .. "/?.lua;"
  .. root
  .. "/clients/?.lua;"
  .. root
  .. "/clients/?/init.lua;"
  .. package.path

local diff = require("verify.conform.diff")
local context = require("verify.conform.context")
local lib = require("verify.conform.lib")

local runtime = rex_api and "rex" or (rawget(_G, "jit") and "luajit" or _VERSION)
local provider = args.provider
local ctx = context.new(root, provider)

local ORDER = context.CATEGORIES
local wanted = {}
if args.only and args.only ~= "" then
  for name in string.gmatch(args.only, "[^,]+") do
    wanted[name] = true
  end
else
  for _, name in ipairs(ORDER) do
    wanted[name] = true
  end
end

local lines = {}
local function say(s)
  lines[#lines + 1] = s
  print(s)
end

local failed = 0
local summary = {}
for _, category in ipairs(ORDER) do
  if wanted[category] and lib.read(ctx.ref_dir .. "/" .. category .. ".jsonl") then
    local t = context.tally(ctx, category)
    local n, ok, mismatched, skipped, intended_n = t.n, t.ok, t.mismatched, t.skipped, t.intended
    for _, r in ipairs(t.results) do
      if not r.skipped then
        if #r.real > 0 then
          say(
            string.format(
              "MISMATCH %s %s  (case: verify/conform/cases/%s/%s line %d)",
              category,
              r.id,
              provider,
              r.file,
              r.line
            )
          )
          for _, d in ipairs(r.real) do
            say(
              string.format("  %s: distilled %s | lua %s", d.path, diff.show(d.a), diff.show(d.b))
            )
          end
        end
        if args.verbose then
          for _, d in ipairs(r.known) do
            say(string.format("  intended %s %s: %s", r.id, d.path, d.reason))
          end
        end
      end
    end
    failed = failed + mismatched
    summary[#summary + 1] = string.format(
      "  %-9s %4d cases: %4d match (%d with intended differences), %d mismatch, %d skipped",
      category,
      n,
      ok,
      intended_n,
      mismatched,
      skipped
    )
  end
end

say("== conform " .. provider .. " [" .. runtime .. "]")
for _, s in ipairs(summary) do
  say(s)
end
if failed > 0 then
  say("conform: FAIL (" .. failed .. " mismatches)")
  if rex_api then
    error("conform: " .. failed .. " mismatches", 0)
  end
  os.exit(1)
end
say("conform: ok")
