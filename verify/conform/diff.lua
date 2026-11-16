-- Field-level diffs for dl conform: JSON values, URLs (path, query content, query order)
-- and the `want`/`got` records both sides produce. Pure Lua; bounded recursion (the
-- values compared are request and response bodies a few levels deep).
local json = require("distilled.json")

local diff = {}

local function show(v)
  if v == nil then
    return "(absent)"
  end
  if v == json.null then
    return "null"
  end
  if type(v) == "table" then
    local text = json.encode(v)
    if text then
      return #text > 200 and (string.sub(text, 1, 200) .. "...") or text
    end
    return tostring(v)
  end
  if type(v) == "string" then
    local text = json.encode(v)
    return #text > 200 and (string.sub(text, 1, 200) .. "...") or text
  end
  return tostring(v)
end
diff.show = show

local function kind(v)
  if v == nil then
    return "absent"
  end
  if v == json.null then
    return "null"
  end
  if type(v) == "table" then
    -- an empty unmarked table is an empty object, as the encoder treats it
    if json.is_array(v) or (not json.is_object(v) and #v > 0) then
      return "array"
    end
    return "object"
  end
  return type(v)
end

--- diff.values(a, b, path, out): appends { path, a, b } for every difference
function diff.values(a, b, path, out, depth)
  depth = depth or 0
  if depth > 100 then
    out[#out + 1] = { path = path, a = "(too deep)", b = "(too deep)" }
    return out
  end
  local ka, kb = kind(a), kind(b)
  if ka ~= kb then
    out[#out + 1] = { path = path, a = a, b = b }
  elseif ka == "array" then
    local n = math.max(#a, #b)
    for i = 1, n do
      diff.values(a[i], b[i], path .. "[" .. (i - 1) .. "]", out, depth + 1)
    end
  elseif ka == "object" then
    local keys, seen = {}, {}
    for k in pairs(a) do
      keys[#keys + 1], seen[k] = k, true
    end
    for k in pairs(b) do
      if not seen[k] then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, function(x, y)
      return tostring(x) < tostring(y)
    end)
    for _, k in ipairs(keys) do
      diff.values(a[k], b[k], path .. "." .. tostring(k), out, depth + 1)
    end
  elseif a ~= b then
    out[#out + 1] = { path = path, a = a, b = b }
  end
  return out
end

local function unescape(s)
  s = string.gsub(s, "+", " ")
  return (string.gsub(s, "%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- diff.parse_url(u) -> { base_path, query = { {k, v, raw} ... } }
function diff.parse_url(u)
  local path, q = string.match(u, "^([^?#]*)%??([^#]*)")
  local query = {}
  if q and q ~= "" then
    for pair in string.gmatch(q, "[^&]+") do
      local k, v = string.match(pair, "^([^=]*)=?(.*)$")
      local has_eq = string.find(pair, "=", 1, true) ~= nil
      query[#query + 1] = { unescape(k), has_eq and unescape(v) or nil, pair }
    end
  end
  return { path = path, query = query }
end

local function query_key(p)
  return p[1] .. "\0" .. tostring(p[2])
end

--- diff.urls(a, b, out): path (raw), query content (decoded multiset), query order,
--- query encoding (same decoded content, different bytes)
function diff.urls(a, b, out)
  local pa, pb = diff.parse_url(a), diff.parse_url(b)
  if pa.path ~= pb.path then
    out[#out + 1] = { path = "url.path", a = pa.path, b = pb.path }
  end
  local ca, cb = {}, {}
  for _, p in ipairs(pa.query) do
    ca[#ca + 1] = query_key(p)
  end
  for _, p in ipairs(pb.query) do
    cb[#cb + 1] = query_key(p)
  end
  local sa, sb = {}, {}
  for i, k in ipairs(ca) do
    sa[i] = k
  end
  for i, k in ipairs(cb) do
    sb[i] = k
  end
  table.sort(sa)
  table.sort(sb)
  local same_content = #sa == #sb
  if same_content then
    for i = 1, #sa do
      if sa[i] ~= sb[i] then
        same_content = false
        break
      end
    end
  end
  local function pairs_text(list)
    local parts = {}
    for i, p in ipairs(list) do
      parts[i] = p[1] .. "=" .. tostring(p[2])
    end
    return table.concat(parts, "&")
  end
  if not same_content then
    out[#out + 1] = { path = "url.query", a = pairs_text(pa.query), b = pairs_text(pb.query) }
    return out
  end
  local same_order = true
  for i = 1, #ca do
    if ca[i] ~= cb[i] then
      same_order = false
    end
  end
  if not same_order then
    out[#out + 1] = { path = "url.query_order", a = pairs_text(pa.query), b = pairs_text(pb.query) }
    return out
  end
  for i = 1, #pa.query do
    if pa.query[i][3] ~= pb.query[i][3] then
      out[#out + 1] = { path = "url.query_encoding", a = pa.query[i][3], b = pb.query[i][3] }
    end
  end
  return out
end

local function is_json_type(ct)
  return type(ct) == "string" and string.find(string.lower(ct), "json", 1, true) ~= nil
end
diff.is_json_type = is_json_type

--- diff.bodies(a, b, content_type, out): parsed JSON when the content type says JSON and
--- both parse, otherwise the bytes
function diff.bodies(a, b, content_type, out)
  if a == b then
    return out
  end
  if a == nil or b == nil then
    out[#out + 1] = { path = "body", a = a, b = b }
    return out
  end
  if is_json_type(content_type) then
    local va, ea = json.decode(a)
    local vb, eb = json.decode(b)
    if not ea and not eb then
      return diff.values(va, vb, "body", out)
    end
  end
  out[#out + 1] = { path = "body", a = a, b = b }
  return out
end

return diff
