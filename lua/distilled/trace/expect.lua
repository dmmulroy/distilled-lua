-- Assertions over a list of finished spans, for specs and `dl expect` scripts.
--
--   local expect = require("distilled.trace.expect")
--   local e = expect(memory.spans)                    -- or expect(memory_exporter)
--   e:span("Neon.GetProject"):attr("http.response.status_code", 200)
--   e:span("Neon.GetProject"):children("distilled.attempt"):count(3)
--   e:span("Neon.GetProject"):failed("TooManyRequests")
--   e:no_attr_contains("sk-CANARY")
--
-- A selection is a list of spans. Every assertion checks every span in it, returns the
-- same selection (so calls chain) and raises a string on failure that names the
-- selection and shows what was found. Assertions raise on purpose: they are test code.
-- The full API is documented in verify/features/tracing.md.
local compat = require("distilled.compat")
local tree = require("distilled.trace.tree")

local Selection = {}
Selection.__index = Selection

local function fail(sel, message, spans)
  local lines = { "expect: " .. sel._desc .. ": " .. message }
  for i, s in ipairs(spans or {}) do
    if i > 5 then
      lines[#lines + 1] = "  ... (" .. #spans .. " spans)"
      break
    end
    lines[#lines + 1] = "  found: "
      .. tree.render({ s }, { durations = false }):match("\n%s*(.-)\n")
  end
  -- level 3: the user's line (fail <- assertion method <- caller)
  compat.raise(table.concat(lines, "\n"), 3)
end

local function new_selection(ctx, list, desc)
  return setmetatable({ _ctx = ctx, _list = list, _desc = desc }, Selection)
end

local function names_of(list)
  local seen, out = {}, {}
  for _, s in ipairs(list) do
    if not seen[s.name] then
      seen[s.name] = true
      out[#out + 1] = string.format("%q", tostring(s.name))
    end
  end
  if #out == 0 then
    return "(no spans)"
  end
  return table.concat(out, ", ")
end

-- the selection's spans and all their descendants, in tree order
local function with_descendants(sel)
  local ctx = sel._ctx
  local out, seen = {}, {}
  local stack = {}
  for i = #sel._list, 1, -1 do
    stack[#stack + 1] = sel._list[i]
  end
  while #stack > 0 do
    local s = table.remove(stack)
    if not seen[s] then
      seen[s] = true
      out[#out + 1] = s
      local kids = ctx.children[s] or {}
      for i = #kids, 1, -1 do
        stack[#stack + 1] = kids[i]
      end
    end
  end
  return out
end

local function same_value(a, b)
  if type(a) == "table" and type(b) == "table" then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if a[i] ~= b[i] then
        return false
      end
    end
    return true
  end
  return a == b
end

local function show(v)
  if v == nil then
    return "nothing"
  end
  return tree.show_value(v)
end

--- expect(spans | memory_exporter) -> selection of every span
local function expect(spans)
  if type(spans) == "table" and type(rawget(spans, "spans")) == "table" then
    spans = spans.spans
  end
  if type(spans) ~= "table" then
    compat.raise("expect: expected a list of spans or a memory exporter", 2)
  end
  local ctx = { children = {}, parent = {}, by_id = {} }
  local ordered = {}
  for _, group in ipairs(tree.order(spans)) do
    local path = {}
    for _, item in ipairs(group.spans) do
      local s, depth = item[1], item[2]
      ordered[#ordered + 1] = s
      path[depth + 1] = s
      for d = #path, depth + 2, -1 do
        path[d] = nil
      end
      local p = path[depth]
      if p then
        ctx.parent[s] = p
        ctx.children[p] = ctx.children[p] or {}
        table.insert(ctx.children[p], s)
      end
    end
  end
  ctx.roots = ordered
  return new_selection(ctx, ordered, "all spans")
end

--- sel:span(name) -> the one span with that name among the selection and its
-- descendants. Fails when there is none or more than one (use :spans for several).
function Selection:span(name)
  local found = {}
  for _, s in ipairs(with_descendants(self)) do
    if s.name == name then
      found[#found + 1] = s
    end
  end
  if #found ~= 1 then
    fail(
      self,
      string.format(
        "expected one span %q, found %d; span names: %s",
        name,
        #found,
        names_of(with_descendants(self))
      ),
      found
    )
  end
  return new_selection(self._ctx, found, string.format("span %q", name))
end

--- sel:spans([name]) -> every span (with that name) among the selection and descendants
function Selection:spans(name)
  local found = {}
  for _, s in ipairs(with_descendants(self)) do
    if name == nil or s.name == name then
      found[#found + 1] = s
    end
  end
  return new_selection(self._ctx, found, name and string.format("spans %q", name) or "spans")
end

--- sel:children([name]) -> the direct children of every selected span, in start order
function Selection:children(name)
  local found = {}
  for _, s in ipairs(self._list) do
    for _, c in ipairs(self._ctx.children[s] or {}) do
      if name == nil or c.name == name then
        found[#found + 1] = c
      end
    end
  end
  local what = name and string.format("children %q", name) or "children"
  return new_selection(self._ctx, found, self._desc .. " > " .. what)
end

--- sel:parent() -> the parent of every selected span (fails for a root)
function Selection:parent()
  local found = {}
  for _, s in ipairs(self._list) do
    local p = self._ctx.parent[s]
    if not p then
      fail(self, "has no parent in the trace", { s })
    end
    found[#found + 1] = p
  end
  return new_selection(self._ctx, found, self._desc .. " > parent")
end

--- sel:nth(i) -> the i-th selected span
function Selection:nth(i)
  local s = self._list[i]
  if not s then
    fail(self, string.format("no span #%d, the selection has %d", i, #self._list), self._list)
  end
  return new_selection(self._ctx, { s }, self._desc .. " #" .. i)
end

--- sel:count(n): the selection holds exactly n spans
function Selection:count(n)
  if #self._list ~= n then
    fail(self, string.format("expected %d spans, found %d", n, #self._list), self._list)
  end
  return self
end

--- sel:attr(key [, value]): every selected span has the attribute (equal to value)
function Selection:attr(key, value)
  if #self._list == 0 then
    fail(self, "no spans to check attribute " .. key)
  end
  for _, s in ipairs(self._list) do
    local actual = s.attributes and s.attributes[key]
    if actual == nil or (value ~= nil and not same_value(actual, value)) then
      fail(
        self,
        string.format(
          "attribute %s: expected %s, found %s",
          key,
          value == nil and "a value" or show(value),
          show(actual)
        ),
        { s }
      )
    end
  end
  return self
end

--- sel:no_attr(key): no selected span has the attribute
function Selection:no_attr(key)
  for _, s in ipairs(self._list) do
    local actual = s.attributes and s.attributes[key]
    if actual ~= nil then
      fail(self, string.format("attribute %s: expected none, found %s", key, show(actual)), { s })
    end
  end
  return self
end

--- sel:failed([tag]): every selected span has status error (and error.type == tag)
function Selection:failed(tag)
  if #self._list == 0 then
    fail(self, "no spans to check for failure")
  end
  for _, s in ipairs(self._list) do
    local code = s.status and s.status.code
    local actual = s.attributes and s.attributes["error.type"]
    if code ~= "error" then
      fail(self, "expected a failed span, status is " .. tostring(code), { s })
    end
    if tag ~= nil and actual ~= tag then
      fail(self, string.format("expected error.type %s, found %s", tag, show(actual)), { s })
    end
  end
  return self
end

--- sel:ok(): no selected span failed (status unset or ok)
function Selection:ok()
  for _, s in ipairs(self._list) do
    if s.status and s.status.code == "error" then
      fail(self, "expected no failure, status is error", { s })
    end
  end
  return self
end

--- sel:event(name [, attrs]): every selected span has an event with that name (whose
-- attributes include attrs)
function Selection:event(name, attrs)
  if #self._list == 0 then
    fail(self, "no spans to check event " .. name)
  end
  for _, s in ipairs(self._list) do
    local hit = false
    for _, e in ipairs(s.events or {}) do
      if e.name == name then
        hit = true
        for k, v in pairs(attrs or {}) do
          if not same_value(e.attributes and e.attributes[k], v) then
            hit = false
          end
        end
        if hit then
          break
        end
      end
    end
    if not hit then
      fail(
        self,
        string.format("expected event %q%s", name, attrs and " with those attributes" or ""),
        { s }
      )
    end
  end
  return self
end

local function contains(v, needle)
  if type(v) == "table" then
    for i = 1, #v do
      if contains(v[i], needle) then
        return true
      end
    end
    return false
  end
  return v ~= nil and string.find(tostring(v), needle, 1, true) ~= nil
end

--- sel:no_attr_contains(needle): the plain substring appears in no span name, attribute
-- key or value, event name or attribute, or status message of any selected span or
-- descendant. Used with canary secrets.
function Selection:no_attr_contains(needle)
  for _, s in ipairs(with_descendants(self)) do
    local where
    if contains(s.name, needle) then
      where = "span name"
    end
    for k, v in pairs(s.attributes or {}) do
      if not where and (contains(k, needle) or contains(v, needle)) then
        where = "attribute " .. k
      end
    end
    for _, e in ipairs(s.events or {}) do
      if not where and contains(e.name, needle) then
        where = "event name " .. tostring(e.name)
      end
      for k, v in pairs(e.attributes or {}) do
        if not where and (contains(k, needle) or contains(v, needle)) then
          where = "event " .. tostring(e.name) .. " attribute " .. k
        end
      end
    end
    if not where and s.status and contains(s.status.message, needle) then
      where = "status message"
    end
    if where then
      fail(self, string.format("%q found in %s of span %q", needle, where, tostring(s.name)), { s })
    end
  end
  return self
end

--- sel:list() -> the selected span records; sel:get([i]) -> one record (default 1)
function Selection:list()
  return self._list
end

function Selection:get(i)
  return self._list[i or 1]
end

--- sel:tree() -> tree.render of the selection and its descendants
function Selection:tree(opts)
  return tree.render(with_descendants(self), opts)
end

return setmetatable({ Selection = Selection }, {
  __call = function(_, spans)
    return expect(spans)
  end,
})
