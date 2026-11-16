-- Lua source writer: turns generator values into deterministic, stylua-clean source.
--
-- Values:
--   strings, numbers, booleans          literals
--   emit.raw("S.string")                code inserted verbatim
--   emit.call("S.ref", "Project")       a call with literal arguments: S.ref("Project")
--   emit.list{ ... }                    a sequence, always emitted as { a, b } (even empty)
--   other tables                        records; keys in FIELD_ORDER first, then sorted
--
-- Layout follows stylua (stylua.toml: 100 columns, 2 spaces, double quotes): a table goes
-- on one line when that line fits in 100 columns, otherwise one entry per line with a
-- trailing comma. stylua keeps an expanded table expanded and an inline table that fits
-- inline, so output written this way passes `stylua --check` unchanged.
local naming = require("distilled.gen.naming")

local emit = {}

emit.WIDTH = 100
emit.INDENT = "  "

local RAW = {}
local CALL = {}
local LIST = {}

function emit.raw(code)
  return setmetatable({ code = code }, RAW)
end

function emit.call(fn, ...)
  return setmetatable({ fn = fn, args = { ... }, n = select("#", ...) }, CALL)
end

function emit.list(t)
  return setmetatable({ items = t or {} }, LIST)
end

function emit.is_list(v)
  return getmetatable(v) == LIST
end

-- Record keys emitted first, in this order; any other key follows, sorted.
emit.FIELD_ORDER = {
  -- schema nodes and members
  "t",
  "op",
  "header",
  "name",
  "tag",
  "key",
  "wire",
  "bind",
  "schema",
  "required",
  "nullable",
  "sensitive",
  "greedy",
  "style",
  "string_encoded",
  "base",
  "values",
  "item",
  "value",
  "arms",
  "discriminator",
  "open",
  "members",
  -- operations
  "method",
  "uri",
  "code",
  "content_type",
  "body_media_type",
  "input",
  "output",
  "output_raw",
  "errors",
  "pagination",
  "retry",
  "span",
  "mode",
  "input_token",
  "output_token",
  "items",
  "page_size",
  "has_next_page",
  -- error classes
  "categories",
  "retryable",
  "throttling",
  "matchers",
  "fields",
  -- error matchers
  "status",
  "message",
  "body",
  "headers",
  -- telemetry
  "system",
  "prefix",
  "service",
  "labels",
  "label_names",
  "attributes",
  "templates",
  "propagate",
  "response_headers",
  -- client options
  "secret",
  "default",
  "env",
}
local RANK = {}
for i, k in ipairs(emit.FIELD_ORDER) do
  RANK[k] = i
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then
      return ta < tb
    end
    if ta == "number" then
      return a < b
    end
    local ra, rb = RANK[a], RANK[b]
    if ra and rb then
      return ra < rb
    end
    if ra or rb then
      return ra ~= nil
    end
    return a < b
  end)
  return keys
end
emit.sorted_keys = sorted_keys

--- emit.string(s) -> a Lua string literal (stylua AutoPreferDouble quoting)
function emit.string(s)
  local quote = '"'
  if string.find(s, '"', 1, true) and not string.find(s, "'", 1, true) then
    quote = "'"
  end
  local out = string.gsub(s, "[%c\\" .. quote .. "\128-\255]", function(c)
    if c == "\\" then
      return "\\\\"
    elseif c == quote then
      return "\\" .. c
    elseif c == "\n" then
      return "\\n"
    elseif c == "\t" then
      return "\\t"
    elseif c == "\r" then
      return "\\r"
    elseif string.byte(c) >= 128 then
      -- UTF-8 bytes stay as they are (stylua leaves them; widths count characters)
      return c
    end
    return string.format("\\%03d", string.byte(c))
  end)
  return quote .. out .. quote
end

function emit.number(n)
  if n ~= n or n == 1 / 0 or n == -1 / 0 then
    error("emit: cannot write a non-finite number", 2)
  end
  if n == math.floor(n) and n > -2 ^ 53 and n < 2 ^ 53 then
    return string.format("%d", n)
  end
  return string.format("%.17g", n)
end

--- emit.key(k) -> "k = " or '["k"] = ' or "[1] = "
function emit.key(k)
  if type(k) == "number" then
    return "[" .. emit.number(k) .. "] = "
  end
  if naming.is_identifier(k) then
    return k .. " = "
  end
  return "[" .. emit.string(k) .. "] = "
end

-- display width of a line: UTF-8 characters, not bytes
local function width(s)
  local _, cont = string.gsub(s, "[\128-\191]", "")
  return #s - cont
end
emit.width = width

local inline -- forward

local function is_sequence(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return n > 0
end

-- entries(v) -> list of { key_text, value } for a table value (records and lists)
local function entries(v)
  local out = {}
  if getmetatable(v) == LIST then
    for i = 1, #v.items do
      out[i] = { "", v.items[i] }
    end
    return out
  end
  if is_sequence(v) then
    for i = 1, #v do
      out[i] = { "", v[i] }
    end
    return out
  end
  for _, k in ipairs(sorted_keys(v)) do
    out[#out + 1] = { emit.key(k), v[k] }
  end
  return out
end

-- inline(v) -> single-line source (may be long)
function inline(v)
  local tv = type(v)
  if tv == "string" then
    return emit.string(v)
  elseif tv == "number" then
    return emit.number(v)
  elseif tv == "boolean" then
    return tostring(v)
  elseif tv == "nil" then
    return "nil"
  end
  local mt = getmetatable(v)
  if mt == RAW then
    return v.code
  elseif mt == CALL then
    local args = {}
    for i = 1, v.n do
      args[i] = inline(v.args[i])
    end
    return v.fn .. "(" .. table.concat(args, ", ") .. ")"
  end
  local es = entries(v)
  if #es == 0 then
    return "{}"
  end
  local parts = {}
  for i, e in ipairs(es) do
    parts[i] = e[1] .. inline(e[2])
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end
emit.inline = inline

local function expandable(v)
  if type(v) ~= "table" then
    return false
  end
  local mt = getmetatable(v)
  if mt == RAW then
    return false
  end
  if mt == CALL then
    -- a call expands only through a table argument; generator calls take literals
    return false
  end
  return #entries(v) > 0
end

--- emit.value(v, indent, prefix, suffix) -> lines (a list of strings)
-- prefix is the text before the value on its first line (indent excluded), suffix the
-- text after it on its last line (for example ",").
function emit.value(v, indent, prefix, suffix)
  indent = indent or ""
  prefix = prefix or ""
  suffix = suffix or ""
  local one = indent .. prefix .. inline(v) .. suffix
  if width(one) <= emit.WIDTH or not expandable(v) then
    return { one }
  end
  local lines = { indent .. prefix .. "{" }
  local inner = indent .. emit.INDENT
  for _, e in ipairs(entries(v)) do
    for _, l in ipairs(emit.value(e[2], inner, e[1], ",")) do
      lines[#lines + 1] = l
    end
  end
  lines[#lines + 1] = indent .. "}" .. suffix
  return lines
end

--- emit.assign(target, v) -> lines for `target = <v>`
function emit.assign(target, v)
  return emit.value(v, "", target .. " = ", "")
end

--- emit.comment(text [, indent]) -> "-- " lines, wrapped at WIDTH on spaces
function emit.comment(text, indent, lead)
  indent = indent or ""
  lead = lead or "-- "
  local lines = {}
  for para in string.gmatch(text .. "\n", "(.-)\n") do
    if para == "" then
      lines[#lines + 1] = indent .. string.gsub(lead, "%s+$", "")
    else
      local line = ""
      for word in string.gmatch(para, "%S+") do
        if line == "" then
          line = word
        elseif width(indent .. lead .. line .. " " .. word) <= emit.WIDTH then
          line = line .. " " .. word
        else
          lines[#lines + 1] = indent .. lead .. line
          line = word
        end
      end
      lines[#lines + 1] = indent .. lead .. line
    end
  end
  return lines
end

--- emit.Buffer: an append-only list of lines
local Buffer = {}
Buffer.__index = Buffer

function emit.buffer()
  return setmetatable({ lines = {} }, Buffer)
end

function Buffer:line(s)
  self.lines[#self.lines + 1] = s or ""
  return self
end

function Buffer:lines_of(list)
  for _, l in ipairs(list) do
    self.lines[#self.lines + 1] = l
  end
  return self
end

function Buffer:blank()
  if #self.lines > 0 and self.lines[#self.lines] ~= "" then
    self.lines[#self.lines + 1] = ""
  end
  return self
end

function Buffer:text()
  local out = {}
  for i, l in ipairs(self.lines) do
    -- no trailing whitespace anywhere
    out[i] = (string.gsub(l, "%s+$", ""))
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n") .. "\n"
end

return emit
