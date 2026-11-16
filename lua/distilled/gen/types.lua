-- LuaLS definitions (`---@meta`) for a generated client.
--
-- Written against the LuaCATS annotation reference (https://luals.github.io/wiki/annotations/):
-- `---@class` + `---@field name? type description` per structure, `---@field [string] any`
-- for open structures, `---@alias` for lists, maps, enums and unions, and a documented
-- method per operation on `<name>.Client`. lua-language-server is not installed here, so
-- this is checked by reading, not by a tool.
--
-- Enum aliases list their values; members of request-reachable shapes accept any string
-- too (`| string`), as Distilled re-opens enums on the request side so callers can send
-- values newer than the model.
local compat = require("distilled.compat")
local emit = require("distilled.gen.emit")
local naming = require("distilled.gen.naming")
local shapes = require("distilled.gen.shapes")

local types = {}

local SCALAR_TYPE = {
  string = "string",
  number = "number",
  boolean = "boolean",
  timestamp = "string",
  blob = "string",
  unknown = "any",
  unit = "table",
}

-- Shared runtime types. Every generated types.lua declares them (LuaLS merges repeated
-- class declarations), so a client's definitions work without anything else.
local RUNTIME_TYPES = [[
---@class distilled.Error
---@field tag string
---@field message string
---@field categories table<string, boolean>
---@field retryable boolean
---@field throttling boolean
---@field status? number
---@field code? string|number
---@field body? any
---@field headers? table<string, string>
---@field retry_after? number
---@field trace_id? string
---@field cause? distilled.Error|string

---@class distilled.Secret

---A file part of a multipart body: `distilled.file{ data, filename?, content_type? }`.
---@class distilled.File
---@field data string|distilled.Secret The bytes
---@field filename? string Defaults to the member's wire name
---@field content_type? string Defaults to application/octet-stream

---JSON null (`distilled.null`): a value that is present and null, unlike nil.
---@class distilled.Null

---A paginated traversal: call it in a `for` loop; it stops at the first failure and
---records it in `err`.
---@class distilled.Iterator<T>
---@field err? distilled.Error
---@field collect fun(self: distilled.Iterator<T>, limit?: integer): T[]?, distilled.Error?
---@field close fun(self: distilled.Iterator<T>)
---@operator call: T?]]

local function doc_lines(doc, indent)
  local out = {}
  if type(doc) ~= "string" or doc == "" then
    return out
  end
  doc = string.gsub(doc, "\r\n?", "\n")
  doc = string.gsub(doc, "%s+$", "")
  for raw in string.gmatch(doc .. "\n", "(.-)\n") do
    local line = string.gsub(raw, "%s+$", "")
    if string.sub(line, 1, 1) == "@" then
      -- would read as an annotation
      line = " " .. line
    end
    out[#out + 1] = (indent or "") .. "---" .. line
  end
  return out
end

local function field_key(name)
  if naming.is_identifier(name) then
    return name
  end
  return "[" .. emit.string(name) .. "]"
end

--- types.type_of(ctx, prefix, target, request_side) -> LuaLS type text
function types.type_of(ctx, prefix, target, request_side)
  local kind = ctx.model:scalar(target)
  if naming.is_prelude(target) then
    return SCALAR_TYPE[kind] or "any"
  end
  local def = ctx.model.shapes[target]
  local t = prefix .. "." .. naming.local_name(target)
  if request_side and def and def.type == "enum" then
    return t .. "|string"
  end
  if request_side and def and def.type == "intEnum" then
    return t .. "|number"
  end
  return t
end

-- A Blob member of a multipart input is a file part: a distilled.File, or a string of
-- bytes (sent as a file named after the member, like Distilled's Uint8Array). A list of
-- Blobs is one part per element.
local function file_type(ctx, target)
  if ctx.model:scalar(target) == "blob" then
    return "distilled.File|string"
  end
  local def = ctx.model.shapes[target]
  if
    def
    and (def.type == "list" or def.type == "set")
    and ctx.model:scalar(def.member.target) == "blob"
  then
    return "(distilled.File|string)[]"
  end
  return nil
end

local function member_type(ctx, prefix, info, request_side, multipart_input)
  local t = multipart_input and file_type(ctx, info.target)
    or types.type_of(ctx, prefix, info.target, request_side)
  if info.sensitive then
    t = request_side and (t .. "|distilled.Secret") or "distilled.Secret"
  end
  if info.nullable then
    t = t .. "|distilled.Null"
  end
  return t
end

-- A list item or map value: a sparse list or map (the nullable trait on the element)
-- holds json.null too.
local function element_type(ctx, prefix, mem, request_side)
  local t = types.type_of(ctx, prefix, mem.target, request_side)
  if mem.traits and mem.traits["com.distilled.openapi#nullable"] ~= nil then
    t = t .. "|distilled.Null"
  end
  return t
end

local function needs_parens(t)
  return string.find(t, "|", 1, true) ~= nil
end

--- types.render(plan) -> source of types.lua
function types.render(plan)
  local ctx, spec = plan.ctx, plan.provider
  local prefix = spec.name
  local b = emit.buffer()
  b:line("---@meta")
  b:lines_of(
    require("distilled.gen.writer").header(
      plan,
      "LuaLS definitions for the " .. spec.title .. " client."
    )
  )
  b:line("-- Never required at run time; point lua-language-server's workspace.library here.")
  b:blank()
  for line in string.gmatch(RUNTIME_TYPES .. "\n", "(.-)\n") do
    b:line(line)
  end
  b:blank()

  local req = ctx.request_reachable
  local multipart_inputs = {}
  for _, op in ipairs(plan.ops) do
    if op.http.content_type == "multipart" and op.input then
      multipart_inputs[op.input] = true
    end
  end
  for _, n in ipairs(plan.nodes) do
    local id = n.id
    local def = ctx.model.shapes[id]
    local tname = prefix .. "." .. n.name
    local request_side = req[id] == true
    local doc = def.traits and def.traits["smithy.api#documentation"]
    b:lines_of(doc_lines(doc))
    if def.type == "structure" then
      b:line("---@class " .. tname)
      for _, info in ipairs(shapes.members(ctx, def, id)) do
        local desc = naming.one_line(info.doc)
        local line = "---@field "
          .. field_key(info.name)
          .. (info.required and "" or "?")
          .. " "
          .. member_type(ctx, prefix, info, request_side, multipart_inputs[id])
        if desc then
          line = line .. " " .. desc
        end
        b:line(line)
      end
      if def.traits and def.traits["com.distilled.openapi#additionalProperties"] ~= nil then
        b:line("---@field [string] any")
      end
    elseif def.type == "list" or def.type == "set" then
      local item = element_type(ctx, prefix, def.member, request_side)
      if needs_parens(item) then
        item = "(" .. item .. ")"
      end
      b:line("---@alias " .. tname .. " " .. item .. "[]")
    elseif def.type == "map" then
      b:line(
        "---@alias "
          .. tname
          .. " { [string]: "
          .. element_type(ctx, prefix, def.value, request_side)
          .. " }"
      )
    elseif def.type == "enum" or def.type == "intEnum" then
      local values = {}
      for i, v in ipairs(shapes.enum_values(ctx, def)) do
        values[i] = type(v) == "string" and emit.string(v) or emit.number(v)
      end
      b:line("---@alias " .. tname .. " " .. compat.concat(values, "|"))
    elseif def.type == "union" then
      local arms = {}
      for i, target in ipairs(shapes.union_arms(ctx, id, def)) do
        arms[i] = types.type_of(ctx, prefix, target, request_side)
      end
      b:line("---@alias " .. tname .. " " .. compat.concat(arms, "|"))
    else
      b:line("---@alias " .. tname .. " " .. (SCALAR_TYPE[ctx.model:scalar(id)] or "any"))
    end
    b:blank()
  end

  -- error classes: documented body types
  for _, d in ipairs(plan.errors) do
    b:lines_of(doc_lines(d.doc))
    b:line("---@class " .. prefix .. "." .. d.tag .. "Error: distilled.Error")
    b:line('---@field tag "' .. d.tag .. '"')
    if #d.bodies > 0 then
      local list = {}
      for i, t in ipairs(d.bodies) do
        list[i] = types.type_of(ctx, prefix, t, false)
      end
      list[#list + 1] = "string"
      b:line("---@field body? " .. compat.concat(list, "|"))
    end
    b:blank()
  end

  -- options and the client
  b:line("---@class " .. prefix .. ".Options")
  if spec.auth.kind ~= "none" then
    b:line(
      "---@field "
        .. spec.auth.from
        .. "? string|distilled.Secret|fun(host: table): (string|distilled.Secret|nil, distilled.Error?)"
        .. (spec.auth.env and (" Required; default from $" .. spec.auth.env) or " Required")
    )
  end
  b:line(
    "---@field "
      .. spec.base_url.option
      .. "? string Default "
      .. spec.base_url.default
      .. (spec.base_url.env and (" (or $" .. spec.base_url.env .. ")") or "")
  )
  b:line("---@field host? table The host seams: transport, sleep, now, exec, random, getenv, epoch")
  b:line("---@field transport? fun(request: table): (table?, distilled.Error?)")
  b:line("---@field sleep? fun(seconds: number)")
  b:line("---@field now? fun(): number")
  b:line("---@field retry? string|table A retry preset or policy fields")
  b:line("---@field deadline_s? number Wall-clock budget for one call, sleeps included")
  b:line('---@field tracing? "off"|"operation"|"debug"|table')
  b:line('---@field validation? "lenient"|"additional"|"strict"')
  b:line("---@field [string] any")
  b:blank()
  b:line("---@class " .. prefix .. ".Module")
  b:line("local Module = {}")
  b:blank()
  b:line("---@param options? " .. prefix .. ".Options")
  b:line("---@return " .. prefix .. ".Client")
  b:line("function Module.new(options) end")
  b:blank()
  b:line("---@class " .. prefix .. ".Client")
  b:line("local Client = {}")
  b:blank()
  b:line("---A client sharing this one's budget, credentials cache and tracer, with overrides.")
  b:line("---@param options " .. prefix .. ".Options")
  b:line("---@return " .. prefix .. ".Client")
  b:line("function Client:with(options) end")
  b:blank()
  b:line("---Flush spans and release what the client holds.")
  b:line("function Client:close() end")
  b:blank()

  for _, op in ipairs(plan.ops) do
    local input_t = prefix .. "." .. naming.local_name(op.input)
    local has_required = false
    for _, info in ipairs(shapes.members(ctx, ctx.model.shapes[op.input], op.input)) do
      has_required = has_required or info.required
    end
    local param = "---@param input" .. (has_required and " " or "? ") .. input_t
    local output_t
    if op.out.raw then
      output_t = types.type_of(ctx, prefix, op.out.type_target, false)
      if op.out.nullable then
        output_t = output_t .. "|distilled.Null"
      end
    else
      output_t = prefix .. "." .. naming.local_name(op.output)
    end
    local doc = op.def.traits and op.def.traits["smithy.api#documentation"]
    local errs = {}
    for i, tag in ipairs(op.error_tags) do
      errs[i] = tag
    end
    local function method(name, ret, extra_doc)
      b:lines_of(doc_lines(doc))
      if extra_doc then
        if doc then
          b:line("---")
        end
        b:line("---" .. extra_doc)
      end
      b:line("---")
      b:line("---`" .. op.http.method .. " " .. op.http.uri .. "`")
      if #errs > 0 then
        b:line("---Errors: " .. compat.concat(errs, ", ") .. ".")
      end
      b:line(param)
      for _, r in ipairs(ret) do
        b:line("---@return " .. r)
      end
      b:line("function Client:" .. name .. "(input) end")
      b:blank()
    end
    local out_ret = needs_parens(output_t) and ("(" .. output_t .. ")?") or (output_t .. "?")
    method(op.method_name, { out_ret .. " value", "distilled.Error? err" })
    if op.pagination then
      method(
        op.method_name .. "_pages",
        { "distilled.Iterator<" .. output_t .. ">" },
        "Every page, fetched as the loop asks for it."
      )
      local item_t = op.item_target and types.type_of(ctx, prefix, op.item_target, false) or "any"
      method(
        op.method_name .. "_items",
        { "distilled.Iterator<" .. item_t .. ">" },
        "Every item of every page (`" .. tostring(op.pagination.items) .. "`)."
      )
    end
  end
  b:line("return Module")
  return b:text()
end

return types
