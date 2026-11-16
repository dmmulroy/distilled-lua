local t = require("spec.harness")
local regex = require("distilled.regex")
local json = require("distilled.json")

-- The 36 distinct patterns (38 uses) in Distilled's patches today, from
--   grep -rho '"matches": *"[^"]*"' ../distilled/packages/*/patches
-- (decoded with JSON.parse; the grep cuts the one with an escaped quote).
local PATCH_PATTERNS = {
  " already exists$",
  ".*",
  "DataCatalog.*not found",
  "KMS key is invalid for CreateGrant[\\s\\S]*ARN does not refer to a valid principal",
  "Macie is(n[\226\128\153']t| not) enabled",
  "NamedQuery.*does not exist",
  "Quota limit '\\w+Storage\\w*PerRegion' has been exceeded",
  "The function execution role does not have permissions to call|Cannot access stream|Please ensure the role can perform the GetRecords",
  "WorkGroup.*not found",
  "[Bb]ucket",
  "[Cc]ommitment_end_time|cannot be deleted|committed period|[Pp]recondition|still active",
  "[Ee]nd of sale|Editions commitment|Plan must be",
  "^Agent \\S+/agents/\\S+ not found",
  "^Cannot (GET|POST|PATCH|DELETE) /api/warm-pools",
  "^Cannot POST /api/sandbox/[^/]+/resize",
  "^Cluster id .* is not valid",
  "^Configuration file 'nodes/[^/']+/lxc/[0-9]+\\.conf' does not exist$",
  "^Configuration file 'nodes/[^/']+/qemu-server/[0-9]+\\.conf' does not exist$",
  "^Location .* is not found",
  "^Security configuration with name .* does not exist",
  "^SecurityConfiguration with name .* already exists",
  "^Service account .+ does not exist\\.?$",
  "^Task .* is not found",
  "^deadline_exceeded: machine failed to reach desired state, [a-z_]+, currently [a-z_]+$",
  "^tag .+ does not exist",
  '^tailnet ".*" not found$',
  "backup plan .* not found",
  "backup vault .* not found",
  "cannot be assumed by Lambda|Please add Lambda as a Trusted Entity",
  "cannot get \\w+'s Saas",
  "compute-environment/.* does not exist",
  "doesn't have (spot )?GPU credits",
  "job-queue/.* does not exist",
  "must be (created and )?valid before attaching",
  "resource .* is not found",
  "unable to assume the provided NetworkConnectorOperatorRole|invalid ConnectorOperatorRole permissions",
}

-- { pattern, text, what `new RegExp(pattern).test(text)` returns in Node }, recorded
-- with node 24 (the generator script is in tasks/03-wire.done.md). The "differential"
-- test below re-runs Node on this table when it can.
local CASES = {
  { " already exists$", "Bucket b already exists", true },
  { " already exists$", "already exists", false },
  { " already exists$", "Bucket already exists.", false },
  { " already exists$", "x already exists\010", false },
  { ".*", "", true },
  { ".*", "anything", true },
  { ".*", "\010", true },
  { "DataCatalog.*not found", "DataCatalog foo was not found", true },
  { "DataCatalog.*not found", "DataCatalog\010not found", false },
  { "DataCatalog.*not found", "datacatalog not found", false },
  {
    "KMS key is invalid for CreateGrant[\092s\092S]*ARN does not refer to a valid principal",
    "KMS key is invalid for CreateGrant.\010The ARN does not refer to a valid principal",
    true,
  },
  {
    "KMS key is invalid for CreateGrant[\092s\092S]*ARN does not refer to a valid principal",
    "KMS key is invalid for CreateGrantARN does not refer to a valid principal",
    true,
  },
  {
    "KMS key is invalid for CreateGrant[\092s\092S]*ARN does not refer to a valid principal",
    "KMS key is invalid for CreateGrant: ARN does not refer",
    false,
  },
  { "Macie is(n[\226\128\153']t| not) enabled", "Macie isn\226\128\153t enabled", true },
  { "Macie is(n[\226\128\153']t| not) enabled", "Macie isn't enabled", true },
  { "Macie is(n[\226\128\153']t| not) enabled", "Macie is not enabled", true },
  { "Macie is(n[\226\128\153']t| not) enabled", "Macie isnt enabled", false },
  { "Macie is(n[\226\128\153']t| not) enabled", "Macie isn`t enabled", false },
  { "NamedQuery.*does not exist", "NamedQuery abc does not exist", true },
  { "NamedQuery.*does not exist", "NamedQuery does not exist", true },
  { "NamedQuery.*does not exist", "NamedQuery\010does not exist", false },
  {
    "Quota limit '\092w+Storage\092w*PerRegion' has been exceeded",
    "Quota limit 'SSDStoragePerRegion' has been exceeded",
    true,
  },
  {
    "Quota limit '\092w+Storage\092w*PerRegion' has been exceeded",
    "Quota limit 'SSD_Storage2PerRegion' has been exceeded",
    true,
  },
  {
    "Quota limit '\092w+Storage\092w*PerRegion' has been exceeded",
    "Quota limit 'StoragePerRegion' has been exceeded",
    false,
  },
  {
    "Quota limit '\092w+Storage\092w*PerRegion' has been exceeded",
    "Quota limit 'SSD-StoragePerRegion' has been exceeded",
    false,
  },
  {
    "The function execution role does not have permissions to call|Cannot access stream|Please ensure the role can perform the GetRecords",
    "x: Cannot access stream arn",
    true,
  },
  {
    "The function execution role does not have permissions to call|Cannot access stream|Please ensure the role can perform the GetRecords",
    "Please ensure the role can perform the GetRecords action",
    true,
  },
  {
    "The function execution role does not have permissions to call|Cannot access stream|Please ensure the role can perform the GetRecords",
    "The function execution role does not have permissions to call X",
    true,
  },
  {
    "The function execution role does not have permissions to call|Cannot access stream|Please ensure the role can perform the GetRecords",
    "cannot access stream",
    false,
  },
  { "WorkGroup.*not found", "WorkGroup primary not found", true },
  { "WorkGroup.*not found", "workgroup not found", false },
  { "[Bb]ucket", "Bucket", true },
  { "[Bb]ucket", "no bucket here", true },
  { "[Bb]ucket", "BUCKET", false },
  {
    "[Cc]ommitment_end_time|cannot be deleted|committed period|[Pp]recondition|still active",
    "commitment_end_time set",
    true,
  },
  {
    "[Cc]ommitment_end_time|cannot be deleted|committed period|[Pp]recondition|still active",
    "precondition failed",
    true,
  },
  {
    "[Cc]ommitment_end_time|cannot be deleted|committed period|[Pp]recondition|still active",
    "It is still active",
    true,
  },
  {
    "[Cc]ommitment_end_time|cannot be deleted|committed period|[Pp]recondition|still active",
    "nothing",
    false,
  },
  { "[Ee]nd of sale|Editions commitment|Plan must be", "end of sale", true },
  { "[Ee]nd of sale|Editions commitment|Plan must be", "Plan must be upgraded", true },
  { "[Ee]nd of sale|Editions commitment|Plan must be", "plan must be", false },
  { "^Agent \092S+/agents/\092S+ not found", "Agent projects/p/agents/a1 not found", true },
  { "^Agent \092S+/agents/\092S+ not found", "Agent  /agents/a not found", false },
  { "^Agent \092S+/agents/\092S+ not found", "The Agent p/agents/a not found", false },
  { "^Agent \092S+/agents/\092S+ not found", "Agent p/agents/a b not found", false },
  { "^Cannot (GET|POST|PATCH|DELETE) /api/warm-pools", "Cannot GET /api/warm-pools/x", true },
  { "^Cannot (GET|POST|PATCH|DELETE) /api/warm-pools", "Cannot PUT /api/warm-pools", false },
  { "^Cannot (GET|POST|PATCH|DELETE) /api/warm-pools", "cannot GET /api/warm-pools", false },
  { "^Cannot (GET|POST|PATCH|DELETE) /api/warm-pools", "Cannot DELETE /api/warm-pools", true },
  { "^Cannot POST /api/sandbox/[^/]+/resize", "Cannot POST /api/sandbox/abc/resize", true },
  { "^Cannot POST /api/sandbox/[^/]+/resize", "Cannot POST /api/sandbox//resize", false },
  { "^Cannot POST /api/sandbox/[^/]+/resize", "Cannot POST /api/sandbox/a/b/resize", false },
  { "^Cluster id .* is not valid", "Cluster id 12 is not valid", true },
  { "^Cluster id .* is not valid", "Cluster id  is not valid", true },
  { "^Cluster id .* is not valid", "A Cluster id x is not valid", false },
  {
    "^Configuration file 'nodes/[^/']+/lxc/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/pve/lxc/100.conf' does not exist",
    true,
  },
  {
    "^Configuration file 'nodes/[^/']+/lxc/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/pve/lxc/100xconf' does not exist",
    false,
  },
  {
    "^Configuration file 'nodes/[^/']+/lxc/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/pve/lxc/100.conf' does not exist.",
    false,
  },
  {
    "^Configuration file 'nodes/[^/']+/lxc/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/p'v/lxc/1.conf' does not exist",
    false,
  },
  {
    "^Configuration file 'nodes/[^/']+/qemu-server/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/n1/qemu-server/9.conf' does not exist",
    true,
  },
  {
    "^Configuration file 'nodes/[^/']+/qemu-server/[0-9]+\092.conf' does not exist$",
    "Configuration file 'nodes/n1/qemu-server/.conf' does not exist",
    false,
  },
  { "^Location .* is not found", "Location us-1 is not found", true },
  { "^Location .* is not found", "location x is not found", false },
  {
    "^Security configuration with name .* does not exist",
    "Security configuration with name a does not exist",
    true,
  },
  {
    "^Security configuration with name .* does not exist",
    " Security configuration with name a does not exist",
    false,
  },
  {
    "^SecurityConfiguration with name .* already exists",
    "SecurityConfiguration with name x already exists!",
    true,
  },
  { "^Service account .+ does not exist\092.?$", "Service account a@b does not exist.", true },
  { "^Service account .+ does not exist\092.?$", "Service account a@b does not exist", true },
  { "^Service account .+ does not exist\092.?$", "Service account  does not exist", false },
  { "^Service account .+ does not exist\092.?$", "Service account a does not exist..", false },
  { "^Service account .+ does not exist\092.?$", "Service account a does not exist\010", false },
  { "^Task .* is not found", "Task t1 is not found", true },
  { "^Task .* is not found", "Task  is not found", true },
  {
    "^deadline_exceeded: machine failed to reach desired state, [a-z_]+, currently [a-z_]+$",
    "deadline_exceeded: machine failed to reach desired state, started, currently stopped",
    true,
  },
  {
    "^deadline_exceeded: machine failed to reach desired state, [a-z_]+, currently [a-z_]+$",
    "deadline_exceeded: machine failed to reach desired state, Started, currently stopped",
    false,
  },
  {
    "^deadline_exceeded: machine failed to reach desired state, [a-z_]+, currently [a-z_]+$",
    "deadline_exceeded: machine failed to reach desired state, started, currently ",
    false,
  },
  { "^tag .+ does not exist", "tag v1 does not exist", true },
  { "^tag .+ does not exist", "tag  does not exist", false },
  { "^tag .+ does not exist", "the tag v1 does not exist", false },
  { "^tailnet \034.*\034 not found$", "tailnet \034x.ts.net\034 not found", true },
  { "^tailnet \034.*\034 not found$", "tailnet \034\034 not found", true },
  { "^tailnet \034.*\034 not found$", "tailnet x not found", false },
  { "backup plan .* not found", "backup plan p1 not found", true },
  { "backup plan .* not found", "Backup plan p1 not found", false },
  { "backup vault .* not found", "The backup vault v not found", true },
  {
    "cannot be assumed by Lambda|Please add Lambda as a Trusted Entity",
    "role cannot be assumed by Lambda.",
    true,
  },
  {
    "cannot be assumed by Lambda|Please add Lambda as a Trusted Entity",
    "Please add Lambda as a Trusted Entity",
    true,
  },
  { "cannot be assumed by Lambda|Please add Lambda as a Trusted Entity", "Lambda", false },
  { "cannot get \092w+'s Saas", "cannot get user's Saas", true },
  { "cannot get \092w+'s Saas", "cannot get 's Saas", false },
  { "cannot get \092w+'s Saas", "cannot get a-b's Saas", false },
  {
    "compute-environment/.* does not exist",
    "arn:aws:batch:compute-environment/ce does not exist",
    true,
  },
  { "doesn't have (spot )?GPU credits", "account doesn't have GPU credits", true },
  { "doesn't have (spot )?GPU credits", "account doesn't have spot GPU credits", true },
  { "doesn't have (spot )?GPU credits", "doesn't have spot  GPU credits", false },
  { "job-queue/.* does not exist", "job-queue/q does not exist", true },
  { "job-queue/.* does not exist", "job-queue does not exist", false },
  { "must be (created and )?valid before attaching", "cert must be valid before attaching", true },
  {
    "must be (created and )?valid before attaching",
    "must be created and valid before attaching",
    true,
  },
  {
    "must be (created and )?valid before attaching",
    "must be created valid before attaching",
    false,
  },
  { "resource .* is not found", "resource x is not found", true },
  { "resource .* is not found", "resource is not found", false },
  {
    "unable to assume the provided NetworkConnectorOperatorRole|invalid ConnectorOperatorRole permissions",
    "invalid ConnectorOperatorRole permissions",
    true,
  },
  {
    "unable to assume the provided NetworkConnectorOperatorRole|invalid ConnectorOperatorRole permissions",
    "unable to assume the provided NetworkConnectorOperatorRole",
    true,
  },
  { "a|b|", "x", true },
  { "^$", "", true },
  { "^$", "a", false },
  { "a{2}", "a", false },
  { "a{2}", "aa", true },
  { "^a{2,3}$", "aaaa", false },
  { "^a{2,}$", "aaaaa", true },
  { "^a{0}$", "", true },
  { "^(ab)+$", "ababab", true },
  { "^(ab)+?$", "abab", true },
  { "^a*?b$", "aaab", true },
  { "x{", "x{", true },
  { "x{1", "x{1", true },
  { "{a}", "{a}", true },
  { "a}", "a}", true },
  { "]", "]", true },
  { "[a-c]+", "bcb", true },
  { "^[^a-c]+$", "xyz", true },
  { "^[^a-c]+$", "xaz", false },
  { "[\092d-z]", "-", true },
  { "[\092w.]+@", "a.b@", true },
  { "^[-a]$", "-", true },
  { "^[a-]$", "-", true },
  { "[]", "a", false },
  { "[^]", "\010", true },
  { "^.$", "\010", false },
  { "^.$", "\013", false },
  { "^.$", "\226\128\168", false },
  { "^.$", "\195\169", true },
  { "^.$", "\240\159\152\128", false },
  { "^..$", "\240\159\152\128", true },
  { "\240\159\152\128", "x\240\159\152\128y", true },
  { "^[\240\159\152\128]$", "\240\159\152\128", false },
  { "^[\240\159\152\128]{2}$", "\240\159\152\128", true },
  { "\092bfoo\092b", "a foo b", true },
  { "\092bfoo\092b", "afoob", false },
  { "\092Boo\092B", "foob", true },
  { "\092d+", "abc123", true },
  { "^\092D+$", "abc", true },
  { "\092s", "a\194\160b", true },
  { "\092s", "a\227\128\128b", true },
  { "^\092S+$", "a\194\160b", false },
  { "\092W", "abc", false },
  { "\092W", "a-c", true },
  { "\092x41", "A", true },
  { "\092u00e9", "\195\169", true },
  { "\092t", "a\009b", true },
  { "\092cJ", "\010", true },
  { "a\092.b", "a.b", true },
  { "a\092.b", "axb", false },
  { "\092/", "a/b", true },
  { "\092e", "e", true },
  { "(?:a|b)c", "bc", true },
  { "(?<n>ab)c", "abc", true },
  { "((a)|b)+c", "abac", true },
  { "(a*)*b", "aaaab", true },
  { "(a*)*b", "aaaa", false },
  { "(a|ab)(c|bcd)(d*)", "abcd", true },
  { "^(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!", false },
  { "a[\092b]b", "a\008b", true },
  { "[\092B]", "B", true },
  { "\0920", "a\000", true },
  { "^\092$", "$", true },
  { "a$", "a\010", false },
  { "^b", "a\010b", false },
}

t.describe("regex: the patterns the patches carry", function()
  t.it("every patch pattern compiles", function()
    t.eq(#PATCH_PATTERNS, 36)
    for _, source in ipairs(PATCH_PATTERNS) do
      local m, err = regex.compile(source)
      t.truthy(m, source .. ": " .. tostring(err))
    end
  end)

  t.it("every patch pattern has recorded Node cases", function()
    local covered = {}
    for _, case in ipairs(CASES) do
      covered[case[1]] = (covered[case[1]] or 0) + 1
    end
    for _, source in ipairs(PATCH_PATTERNS) do
      t.truthy((covered[source] or 0) >= 1, "no case for " .. source)
    end
  end)

  t.it("matches exactly as Node did on the recorded table", function()
    local wrong = {}
    for i, case in ipairs(CASES) do
      local m, err = regex.compile(case[1])
      if not m then
        wrong[#wrong + 1] = i .. ": " .. tostring(err)
      elseif m:test(case[2]) ~= case[3] then
        wrong[#wrong + 1] = i
          .. ": /"
          .. case[1]
          .. "/ on "
          .. string.format("%q", case[2])
          .. " should be "
          .. tostring(case[3])
      end
    end
    t.eq(table.concat(wrong, "\n"), "")
  end)
end)

-- Differential: run Node on the same table now (lua and luajit only: Rex has no
-- io.popen). Skipped when node is not on PATH.
local popen = io and rawget(io, "popen")
local function node_available()
  if not popen then
    return false
  end
  local ok, handle = t.pcall(function()
    return popen("node --version 2>/dev/null")
  end)
  if not ok or not handle then
    return false
  end
  local out = handle:read("*a")
  handle:close()
  return out ~= nil and string.find(out, "^v%d") ~= nil
end

if node_available() then
  t.describe("regex: differential against node -e", function()
    t.it("Node agrees with the recorded table and with this engine", function()
      local list = json.array({})
      for i, case in ipairs(CASES) do
        list[i] = json.array({ case[1], case[2] })
      end
      local path = os.tmpname()
      local f = assert(io.open(path, "wb"))
      f:write(json.encode(list))
      f:close()
      local script = "const c=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));"
        .. "process.stdout.write(c.map(([p,s])=>new RegExp(p).test(s)?'1':'0').join(''))"
      local handle = popen('node -e "' .. script .. '" ' .. path)
      local out = handle:read("*a")
      handle:close()
      os.remove(path)
      t.eq(#out, #CASES)
      local wrong = {}
      for i, case in ipairs(CASES) do
        local node_says = string.sub(out, i, i) == "1"
        local ours = regex.compile(case[1]):test(case[2])
        if node_says ~= case[3] or ours ~= node_says then
          wrong[#wrong + 1] = i .. ": /" .. case[1] .. "/ node " .. tostring(node_says)
        end
      end
      t.eq(table.concat(wrong, "\n"), "")
    end)
  end)
else
  t.pending("regex: differential against node -e (no io.popen or no node here)")
end

t.describe("regex: unsupported syntax fails to compile", function()
  local refused = {
    { "(?=a)", "lookahead" },
    { "(?!a)", "lookahead" },
    { "(?<=a)b", "lookbehind" },
    { "(?<!a)b", "lookbehind" },
    { "(a)\\1", "backreference" },
    { "(?<n>a)\\k<n>", "backreference" },
    { "(?i)abc", "flags" },
    { "(?i:abc)", "flags" },
    { "\\p{L}", "Unicode property" },
    { "\\P{L}", "Unicode property" },
    { "\\u{1F600}", "u flag" },
    { "\\01", "octal" },
    { "*a", "nothing to repeat" },
    { "a**", "nothing to repeat" },
    { "a{2}{3}", "nothing to repeat" },
    { "^*", "nothing to repeat" },
    { "a{3,2}", "out of order" },
    { "[z-a]", "out of order" },
    { "(ab", "unterminated group" },
    { "ab)", "unmatched" },
    { "[ab", "unterminated character class" },
    { "ab\\", "end of pattern" },
  }
  for _, case in ipairs(refused) do
    t.it(case[1] .. " is refused (" .. case[2] .. ")", function()
      local m, err = regex.compile(case[1])
      t.eq(m, nil)
      t.err(m, err, "SdkError")
      t.match(err.message, case[2], true)
      t.match(err.message, case[1], true)
    end)
  end
end)

t.describe("regex: engine", function()
  t.it("test is an unanchored search, like RegExp.test", function()
    local m = regex.compile("b+")
    t.eq(m:test("abbbc"), true)
    t.eq(m:test("ac"), false)
    t.eq(m:test(""), false)
  end)

  t.it("non-string text never matches", function()
    local m = regex.compile(".*")
    t.eq(m:test(nil), false)
    t.eq(m:test(5), false)
    t.eq(m:test(json.null), false)
  end)

  t.it("long text and nested quantifiers stay linear (no stack, no blowup)", function()
    local long = string.rep("a", 20000)
    t.eq(regex.compile("^(a+)+$"):test(long .. "!"), false)
    t.eq(regex.compile("(a*)*b"):test(long), false)
    t.eq(regex.compile("a.*z"):test(long .. "z"), true)
  end)

  t.it("refuses programs over the size limit", function()
    local m, err = regex.compile("(abcdefghij){5000}")
    t.eq(m, nil)
    t.match(err.message, "too large", true)
  end)

  t.it("invalid UTF-8 bytes are characters of their own", function()
    t.eq(regex.compile("^.$"):test("\255"), true)
    t.eq(regex.compile("^[^a]$"):test("\255"), true)
    t.eq(regex.compile("\255"):test("\255"), true) -- the same byte in the pattern
    t.eq(regex.compile("\195\169"):test("\195"), false) -- a broken é is not é
  end)

  t.it("compile raises on a non-string source (misuse)", function()
    t.raises(function()
      regex.compile(5)
    end, "source must be a string")
  end)

  t.it("tostring shows the source", function()
    t.eq(tostring(regex.compile("a|b")), "/a|b/")
  end)
end)

t.describe("regex: errors.match uses it", function()
  local errors = require("distilled.errors")
  t.it("a matches matcher selects the class, the source compiled once", function()
    local source = "^Cannot (GET|POST) /api/warm-pools"
    local C = errors.define({
      tag = "NoWarmPools",
      matchers = { { status = 404, message = { matches = source } } },
    })
    local err = errors.match({ C }, { status = 404, message = "Cannot POST /api/warm-pools/1" })
    t.eq(err.tag, "NoWarmPools")
    local cached = errors._regex_cache[source]
    t.truthy(cached)
    t.eq(errors.match({ C }, { status = 404, message = "Cannot PUT /api/warm-pools" }), nil)
    t.eq(errors._regex_cache[source], cached)
  end)

  t.it("a body pointer matcher can use matches too", function()
    local C = errors.define({
      tag = "Gone",
      matchers = { { body = { ["/detail"] = { matches = "gone|deleted" } } } },
    })
    t.eq(errors.match({ C }, { status = 410, body = { detail = "was deleted" } }).tag, "Gone")
    t.eq(errors.match({ C }, { status = 410, body = { detail = "here" } }), nil)
  end)

  t.it("a source that does not compile never matches", function()
    local C = errors.define({
      tag = "Bad",
      matchers = { { status = 400, message = { matches = "(?=x)" } } },
    })
    t.eq(errors.match({ C }, { status = 400, message = "x" }), nil)
    t.eq(errors._regex_cache["(?=x)"], false)
  end)
end)
