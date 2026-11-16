-- Names the generator emits: snake_case operation methods, Lua identifiers and keys.
--
-- Operation names come from the model's operation shape name (`GetProject`). Distilled
-- lower-firsts them (`getProject`); the Lua surface is snake_case (plan, decision 2), so
-- the rules here are ours. They are written down as cases in spec/gen_naming_spec.lua:
--
--   GetProject                -> get_project
--   ListIPAllowlist           -> list_ip_allowlist      (an acronym ends where a word starts)
--   AddProjectJWKS            -> add_project_jwks       (a trailing acronym is one word)
--   GetV2Thing                -> get_v2_thing           (digits stick to the letters before)
--   GetConsumptionHistoryPerProjectV2 -> get_consumption_history_per_project_v2
--   GetNeonAuthOAuthClient    -> get_neon_auth_oauth_client   (a known mixed-case word)
--
-- Mixed-case words such as "OAuth" cannot be told apart from an acronym followed by a
-- word ("OA" + "uth") by case alone, so they come from a word list: DEFAULT_WORDS, plus
-- the provider's `naming.words`.
local compat = require("distilled.compat")

local naming = {}

naming.DEFAULT_WORDS = { "OAuth", "IPv4", "IPv6", "GraphQL", "MySQL", "PostgreSQL", "macOS" }

-- Lua 5.1 to 5.5 reserved words (5.5 adds `global`; treat it as reserved so a generated
-- client loads on every runtime).
naming.KEYWORDS = {}
for word in
  string.gmatch(
    "and break do else elseif end false for function global goto if in local nil not or "
      .. "repeat return then true until while",
    "%S+"
  )
do
  naming.KEYWORDS[word] = true
end

--- naming.is_identifier(s) -> boolean: a valid Lua name that is not a keyword
function naming.is_identifier(s)
  return type(s) == "string"
    and string.find(s, "^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
    and not naming.KEYWORDS[s]
end

local function sorted_words(words)
  -- Longest first, so "PostgreSQL" wins over a shorter word it contains.
  local list = {}
  for _, w in ipairs(words) do
    list[#list + 1] = w
  end
  table.sort(list, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return list
end

-- Split a PascalCase name into words. Rules, in order, at each position:
-- 1. a word from the word list starting here (case-sensitive) is one word;
-- 2. a run of capitals is an acronym; when lower-case letters follow it, its last
--    capital starts the next word ("IPAllowlist" -> "IP", "Allowlist");
-- 3. a capital followed by lower-case letters is a word;
-- 4. digits join the word before them ("V2", "Project" + "V2" stays "V2").
local function split_words(name, words)
  local out = {}
  local i, n = 1, #name
  while i <= n do
    local matched
    for _, w in ipairs(words) do
      if string.sub(name, i, i + #w - 1) == w then
        -- only at a word boundary: the next character must not continue a lower-case word
        local after = string.sub(name, i + #w, i + #w)
        if after == "" or not string.find(after, "^[a-z]") then
          matched = w
          break
        end
      end
    end
    if matched then
      out[#out + 1] = matched
      i = i + #matched
    else
      local c = string.sub(name, i, i)
      local j
      if string.find(c, "^[A-Z]") then
        local caps_end = select(2, string.find(name, "^[A-Z]+", i))
        if caps_end > i and string.find(string.sub(name, caps_end + 1, caps_end + 1), "^[a-z]") then
          -- acronym followed by a word: the acronym stops before the last capital
          j = caps_end - 1
        elseif caps_end > i then
          j = caps_end
        else
          j = select(2, string.find(name, "^[A-Z][a-z]*", i))
        end
      elseif string.find(c, "^[a-z]") then
        j = select(2, string.find(name, "^[a-z]+", i))
      elseif string.find(c, "^[0-9]") then
        j = select(2, string.find(name, "^[0-9]+", i))
      else
        -- a separator (_ or -): drop it, it is a word boundary
        j = i
        c = nil
      end
      local word = c and string.sub(name, i, j) or nil
      if word then
        if string.find(word, "^[0-9]+$") and #out > 0 then
          out[#out] = out[#out] .. word
        else
          out[#out + 1] = word
        end
      end
      i = j + 1
    end
  end
  return out
end

--- naming.snake_case(name [, words]) -> string
function naming.snake_case(name, words)
  local list = sorted_words(words or naming.DEFAULT_WORDS)
  local parts = split_words(name, list)
  for k, w in ipairs(parts) do
    parts[k] = string.lower(w)
  end
  return compat.concat(parts, "_")
end

--- naming.words(extra) -> the default word list plus extra
function naming.words(extra)
  local list = {}
  for _, w in ipairs(naming.DEFAULT_WORDS) do
    list[#list + 1] = w
  end
  for _, w in ipairs(extra or {}) do
    list[#list + 1] = w
  end
  return list
end

-- Method name suffixes the client adds for paginated operations (decision 6).
naming.PAGE_SUFFIXES = { "_pages", "_items" }

-- Names a generated operation method may not take: the client's own methods.
naming.CLIENT_METHODS = { with = true, close = true, new = true }

--- naming.operation_names(ops, opts) -> { [op_id] = method name } | nil, message
-- ops: list of { id, name, paginated }; opts.words, opts.overrides ({ [OpName] = name }).
-- Fails on a keyword, a non-identifier, a client method name, or two operations (or an
-- operation and another's _pages/_items sibling) landing on the same name.
function naming.operation_names(ops, opts)
  opts = opts or {}
  local words = naming.words(opts.words)
  local overrides = opts.overrides or {}
  local taken = {} -- method name -> description of who took it
  local result = {}
  local problems = {}
  local function claim(method, who)
    if taken[method] then
      problems[#problems + 1] = "operation names collide: "
        .. taken[method]
        .. " and "
        .. who
        .. " are both "
        .. method
      return
    end
    taken[method] = who
  end
  for _, op in ipairs(ops) do
    local method = overrides[op.name] or naming.snake_case(op.name, words)
    if naming.KEYWORDS[method] then
      problems[#problems + 1] = "operation "
        .. op.name
        .. " becomes the Lua keyword "
        .. method
        .. "; add naming.overrides for it to the provider spec"
    elseif not naming.is_identifier(method) then
      problems[#problems + 1] = "operation "
        .. op.name
        .. " becomes "
        .. string.format("%q", method)
        .. ", which is not a Lua identifier"
    elseif naming.CLIENT_METHODS[method] then
      problems[#problems + 1] = "operation "
        .. op.name
        .. " becomes "
        .. method
        .. ", a method every client already has"
    else
      claim(method, op.name)
      if op.paginated then
        for _, suffix in ipairs(naming.PAGE_SUFFIXES) do
          claim(method .. suffix, op.name .. " (" .. suffix .. ")")
        end
      end
      result[op.id] = method
    end
  end
  if #problems > 0 then
    table.sort(problems)
    return nil, compat.concat(problems, "\n")
  end
  return result
end

--- naming.local_name("ns#Shape") -> "Shape"
function naming.local_name(id)
  return string.match(id, "#(.*)$") or id
end

-- LuaLS type names (types.lua) of a shape: `<provider>.<local name>`, except where the
-- client's own definitions take the name. Distilled needs no rule here (TypeScript has
-- no Client type, and its error classes are the error shapes' own names), so this one
-- is ours: such a shape is typed `<Name>Shape`, then `<Name>Shape2`, `<Name>Shape3`...,
-- the first name no other shape and no client type uses. Only the type name changes;
-- registry keys, struct names and S.ref names stay the model's local names.
naming.TYPE_NAME_SUFFIX = "Shape"

--- naming.client_type_names(error_tags) -> { [type name] = "what takes it" }
-- The names the generated types.lua declares for the client itself.
function naming.client_type_names(error_tags)
  local taken =
    { Client = "the client class", Options = "the client options", Module = "the module" }
  for _, tag in ipairs(error_tags or {}) do
    taken[tag .. "Error"] = "the error class " .. tag
  end
  return taken
end

--- naming.type_names(ids, taken) -> { [shape id] = type name } for the renamed shapes
-- ids: every shape id the types declare, sorted (the order makes the suffixes
-- deterministic); taken: naming.client_type_names(...). A shape not in the result is
-- typed by its local name.
function naming.type_names(ids, taken)
  local used = {}
  for name in pairs(taken) do
    used[name] = true
  end
  for _, id in ipairs(ids) do
    used[naming.local_name(id)] = true
  end
  local renamed = {}
  for _, id in ipairs(ids) do
    local name = naming.local_name(id)
    if taken[name] then
      local base = name .. naming.TYPE_NAME_SUFFIX
      local candidate, k = base, 2
      while used[candidate] do
        candidate = base .. k
        k = k + 1
      end
      used[candidate] = true
      renamed[id] = candidate
    end
  end
  return renamed
end

--- naming.type_name(ctx, id) -> the LuaLS type name of shape id (without the prefix)
function naming.type_name(ctx, id)
  local renamed = ctx and ctx.type_names and ctx.type_names[id]
  return renamed or naming.local_name(id)
end

--- naming.is_prelude(id) -> boolean
function naming.is_prelude(id)
  return string.sub(id, 1, 11) == "smithy.api#"
end

-- Levenshtein distance, for "did you mean" suggestions.
local function distance(a, b)
  local la, lb = #a, #b
  local prev = {}
  for j = 0, lb do
    prev[j] = j
  end
  for i = 1, la do
    local cur = { [0] = i }
    local ca = string.byte(a, i)
    for j = 1, lb do
      local cost = (ca == string.byte(b, j)) and 0 or 1
      local v = prev[j] + 1
      if cur[j - 1] + 1 < v then
        v = cur[j - 1] + 1
      end
      if prev[j - 1] + cost < v then
        v = prev[j - 1] + cost
      end
      cur[j] = v
    end
    prev = cur
  end
  return prev[lb]
end
naming.distance = distance

--- naming.nearest(word, candidates [, n]) -> up to n closest candidates (default 3)
-- Candidates containing the word come first, then by edit distance, then by name.
function naming.nearest(word, candidates, n)
  n = n or 3
  local scored = {}
  for _, c in ipairs(candidates) do
    local d = distance(word, c)
    if string.find(c, word, 1, true) or string.find(word, c, 1, true) then
      d = d - 1000
    end
    scored[#scored + 1] = { c = c, d = d }
  end
  table.sort(scored, function(x, y)
    if x.d ~= y.d then
      return x.d < y.d
    end
    return x.c < y.c
  end)
  local out = {}
  for i = 1, math.min(n, #scored) do
    out[i] = scored[i].c
  end
  return out
end

--- naming.one_line(doc) -> doc collapsed to one line, or nil
function naming.one_line(doc)
  if type(doc) ~= "string" then
    return nil
  end
  local s = string.gsub(doc, "%s+", " ")
  s = string.gsub(s, "^ ", "")
  s = string.gsub(s, " $", "")
  if s == "" then
    return nil
  end
  return s
end

--- naming.summary(doc) -> the first paragraph of doc on one line, or nil
-- Neon's operation docs start with a title line and a blank line; the title is what a
-- one-line listing wants.
function naming.summary(doc)
  if type(doc) ~= "string" then
    return nil
  end
  local first = string.match(doc, "^(.-)\n%s*\n") or doc
  return naming.one_line(first)
end

return naming
