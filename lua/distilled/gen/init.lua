-- The generator: a Smithy JSON model plus a provider spec -> a Lua client.
--
--   local gen = require("distilled.gen")
--   local files, err = gen.generate{
--     model = "models/neon.json" | <Model>,      -- path, or gen.model.load's result
--     provider = "providers/neon.lua" | <spec>, -- path, or a spec table
--     ops = { "get_project", ... } | nil,       -- keep only these (method or model names)
--     telemetry = true,                         -- false: no span / telemetry data
--   }
--   -- files = { ["init.lua"] = source, ["service.lua"] = ..., ["types.lua"] = ...,
--   --           ["README.md"] = ... }, plus files.order (the names, sorted)
--   gen.write(files, "clients/neon")
--
-- Port of Distilled's `generateService` (dev/src/codegen/generator.ts). Its seven steps
-- map to: model.lua (1: collect operations, named I/O), this file (2: reachability; 4:
-- errors), ops.lua (3: pagination; 6: operations), shapes.lua (5: shapes), types.lua and
-- the README (7, our equivalent of the aliases and footer). Everything that can be
-- checked is checked here; generation stops on the first batch of problems.
local compat = require("distilled.compat")
local model_mod = require("distilled.gen.model")
local provider_mod = require("distilled.gen.provider")
local naming = require("distilled.gen.naming")
local shapes = require("distilled.gen.shapes")
local gen_errors = require("distilled.gen.errors")
local ops_mod = require("distilled.gen.ops")
local types_mod = require("distilled.gen.types")
local writer = require("distilled.gen.writer")

local gen = {}

gen.VERSION = "1"
gen.model = model_mod
gen.provider = provider_mod

-- A warning the CLI prints after generating (model.warnings), once per message.
local function warn(m, message)
  for _, w in ipairs(m.warnings) do
    if w == message then
      return
    end
  end
  m.warnings[#m.warnings + 1] = message
end

local function fail(problems)
  if type(problems) == "string" then
    return nil, problems
  end
  table.sort(problems)
  return nil, compat.concat(problems, "\n")
end

-- Resolve `--ops` names (method names or model names) to operations; unknown names fail
-- with the nearest matches.
local function select_ops(m, method_names, wanted)
  if wanted == nil then
    return m.operations
  end
  local by_method, by_name, candidates = {}, {}, {}
  for _, op in ipairs(m.operations) do
    by_method[method_names[op.id]] = op
    by_name[op.name] = op
    candidates[#candidates + 1] = method_names[op.id]
  end
  table.sort(candidates)
  local chosen, problems = {}, {}
  for _, name in ipairs(wanted) do
    local op = by_method[name] or by_name[name]
    if not op then
      problems[#problems + 1] = "unknown operation "
        .. name
        .. "; nearest: "
        .. compat.concat(naming.nearest(name, candidates, 3), ", ")
    else
      chosen[op.id] = op
    end
  end
  if #problems > 0 then
    return nil, problems
  end
  if next(chosen) == nil then
    return nil, { "--ops selects no operation" }
  end
  local list = {}
  for _, op in ipairs(m.operations) do
    if chosen[op.id] then
      list[#list + 1] = op
    end
  end
  return list
end

--- gen.plan(args) -> plan | nil, message
-- Everything the emitters need, fully validated.
function gen.plan(args)
  if type(args) ~= "table" then
    error("distilled.gen.plan: expected a table", 2)
  end
  local m, spec = args.model, args.provider
  local err
  if type(m) == "string" then
    m, err = model_mod.load(m)
    if not m then
      return nil, err
    end
  end
  if type(spec) == "string" then
    spec, err = provider_mod.load(spec)
    if not spec then
      return nil, err
    end
  elseif type(spec) == "table" and not spec.__validated then
    spec, err = provider_mod.validate(spec)
    if not spec then
      return nil, err
    end
  end
  local telemetry = args.telemetry ~= false
  local ctx = {
    model = m,
    provider = spec,
    words = naming.words(spec.naming.words),
    greedy = {},
    items_root = {},
  }

  -- method names for every operation (collisions are checked over the whole model, so
  -- `--ops` cannot hide one)
  local entries = {}
  for _, op in ipairs(m.operations) do
    entries[#entries + 1] = {
      id = op.id,
      name = op.name,
      paginated = op.def.traits ~= nil and op.def.traits["smithy.api#paginated"] ~= nil,
    }
  end
  local method_names, nerr, page_methods = naming.operation_names(entries, {
    words = spec.naming.words,
    overrides = spec.naming.operations,
  })
  if not method_names then
    return nil, nerr
  end
  for k in pairs(spec.naming.operations) do
    local known = false
    for _, op in ipairs(m.operations) do
      known = known or op.name == k
    end
    if not known then
      return nil, "provider spec naming.operations names an unknown operation " .. k
    end
  end

  local selected, serr = select_ops(m, method_names, args.ops)
  if not selected then
    return fail(serr)
  end

  local problems = {}
  local plan_ops = {}
  -- shared input shapes would get one op's greedy labels: refuse them
  local input_owner = {}
  for _, op in ipairs(selected) do
    local http, herr = ops_mod.http(ctx, op)
    if not http then
      problems[#problems + 1] = herr
    else
      local labels, lerr = ops_mod.uri_labels(http.uri)
      if not labels then
        problems[#problems + 1] = op.id .. ": " .. lerr
      else
        if input_owner[op.input] then
          problems[#problems + 1] = op.id
            .. ": its input "
            .. op.input
            .. " is also the input of "
            .. input_owner[op.input]
        end
        input_owner[op.input] = op.id
        local in_def = m.shapes[op.input]
        if in_def.type ~= "structure" then
          problems[#problems + 1] = op.id .. ": input " .. op.input .. " is not a structure"
        else
          local greedy = {}
          local placeholder = {}
          for _, l in ipairs(labels) do
            placeholder[l.name] = true
            if l.greedy then
              greedy[l.name] = true
            end
          end
          ctx.greedy[op.input] = greedy
          for _, mem in ipairs(m:members(in_def)) do
            local bind = shapes.binding(mem.traits)
            if bind == "label" then
              if not placeholder[mem.name] then
                problems[#problems + 1] = op.id
                  .. ": label member "
                  .. mem.name
                  .. " has no {"
                  .. mem.name
                  .. "} in "
                  .. http.uri
              end
              placeholder[mem.name] = nil
              local tdef = m.shapes[mem.target]
              local enum_label = tdef ~= nil and (tdef.type == "enum" or tdef.type == "intEnum")
              if m:scalar(mem.target) == nil and not enum_label then
                problems[#problems + 1] = op.id
                  .. ": label member "
                  .. mem.name
                  .. " is not a scalar"
              end
            elseif bind == "status" then
              problems[#problems + 1] = op.id
                .. ": input member "
                .. mem.name
                .. " is bound to the response status"
            end
          end
          -- A placeholder no member fills (proxmox `{url_seq}`): Distilled emits the
          -- operation all the same and sends the placeholder as is. We emit it too, and
          -- request.build fills it from an input key of that name or refuses the call.
          local unbound = {}
          for name in pairs(placeholder) do
            unbound[#unbound + 1] = name
          end
          table.sort(unbound)
          for _, name in ipairs(unbound) do
            warn(
              m,
              op.id
                .. ": {"
                .. name
                .. "} in "
                .. http.uri
                .. " has no label member; the caller must pass input."
                .. name
            )
          end
        end
        plan_ops[#plan_ops + 1] = {
          id = op.id,
          name = op.name,
          method_name = method_names[op.id],
          def = op.def,
          input = op.input,
          output = op.output,
          errors = op.errors,
          http = http,
          page_methods = page_methods[op.id],
        }
      end
    end
  end
  if #problems > 0 then
    return fail(problems)
  end

  -- request-reachable shapes (for the @default rule)
  local req_roots = {}
  for _, op in ipairs(plan_ops) do
    req_roots[#req_roots + 1] = op.input
  end
  ctx.request_reachable = m:reachable(req_roots)

  -- 3. pagination, then the output form (which depends on it)
  for _, op in ipairs(plan_ops) do
    local pg, perr = ops_mod.pagination(ctx, op)
    if pg == false then
      problems[#problems + 1] = perr
    else
      op.pagination = pg
      if pg then
        ctx.items_root[op.output] = op.pagination_items_root
        op.item_target = ops_mod.item_type_target(ctx, op.output, pg.items)
      end
    end
  end
  if #problems > 0 then
    return fail(problems)
  end
  -- the items-root rule changes member infos of paginated outputs: drop cached ones
  ctx.member_cache = nil
  for _, op in ipairs(plan_ops) do
    local out, oerr = ops_mod.output(ctx, op)
    if not out then
      problems[#problems + 1] = oerr
    else
      op.out = out
    end
    local retry, rerr = ops_mod.retry(ctx, op)
    if retry == false then
      problems[#problems + 1] = rerr
    else
      op.retry = retry
    end
    local unsupported, uerr = ops_mod.streaming(ctx, op)
    if unsupported == false then
      problems[#problems + 1] = uerr
    else
      op.unsupported = unsupported
    end
  end
  if #problems > 0 then
    return fail(problems)
  end

  -- 4. errors: every error the selected operations name (collectOpErrorIds)
  local error_ids, error_seen = {}, {}
  for _, op in ipairs(plan_ops) do
    op.error_tags = {}
    for _, target in ipairs(op.errors) do
      if not error_seen[target] then
        error_seen[target] = true
        error_ids[#error_ids + 1] = target
      end
      op.error_tags[#op.error_tags + 1] = naming.local_name(target)
    end
  end
  table.sort(error_ids, function(a, b)
    return naming.local_name(a) < naming.local_name(b)
  end)
  local error_classes = {}
  local reserved_tags = { [spec.unknown_tag] = "unknown_tag", [spec.parse_tag] = "parse_tag" }
  for _, id in ipairs(error_ids) do
    local d, eerr = gen_errors.class(ctx, id)
    if not d then
      problems[#problems + 1] = eerr
    else
      if reserved_tags[d.tag] then
        problems[#problems + 1] = id
          .. ": error tag "
          .. d.tag
          .. " is the provider's "
          .. reserved_tags[d.tag]
      end
      d.id = id
      error_classes[#error_classes + 1] = d
    end
  end
  local error_tags_set = {}
  for _, d in ipairs(error_classes) do
    error_tags_set[d.tag] = true
  end
  local builtin = require("distilled.errors").classes
  for status, tag in pairs(spec.status_map or {}) do
    if not error_tags_set[tag] and not builtin[tag] then
      problems[#problems + 1] = "provider spec status_map["
        .. status
        .. "] names "
        .. tag
        .. ", which is neither a built-in error nor an error of the selected operations"
    end
  end
  if spec.unknown_tag == spec.parse_tag then
    problems[#problems + 1] = "provider spec: unknown_tag and parse_tag are the same"
  end
  if #problems > 0 then
    return fail(problems)
  end

  -- documented error bodies (distilled.errors#bodies) for types and the registry
  local bodies = {}
  for _, op in ipairs(plan_ops) do
    local documented = op.def.traits and op.def.traits["distilled.errors#bodies"]
    if documented ~= nil then
      if type(documented) ~= "table" then
        problems[#problems + 1] = op.id .. ": distilled.errors#bodies must be a list"
      else
        for _, target in ipairs(op.errors) do
          local statuses = gen_errors.statuses(ctx, target)
          for _, b in ipairs(documented) do
            if type(b) ~= "table" or type(b.status) ~= "number" or type(b.target) ~= "string" then
              problems[#problems + 1] = op.id
                .. ": distilled.errors#bodies entries need status and target"
            elseif m.shapes[b.target] == nil and not naming.is_prelude(b.target) then
              problems[#problems + 1] = op.id
                .. ": distilled.errors#bodies target "
                .. b.target
                .. " is not a shape"
            elseif m.shapes[b.target] ~= nil then
              -- A prelude target (a plain smithy.api#String or #Double body, coinflow)
              -- is skipped: there is no shape to document or register, and Distilled
              -- skips a target that is not a model shape the same way.
              for _, s in ipairs(statuses) do
                if s == b.status then
                  bodies[target] = bodies[target] or {}
                  local dup = false
                  for _, x in ipairs(bodies[target]) do
                    dup = dup or x == b.target
                  end
                  if not dup then
                    table.insert(bodies[target], b.target)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  for _, d in ipairs(error_classes) do
    d.bodies = bodies[d.id] or {}
  end
  if #problems > 0 then
    return fail(problems)
  end

  -- 2. reachability: op inputs, outputs (or the raw member's target), error bodies
  local roots = {}
  for _, op in ipairs(plan_ops) do
    roots[#roots + 1] = op.input
    if op.out.root then
      roots[#roots + 1] = op.out.root
    end
  end
  for _, d in ipairs(error_classes) do
    for _, b in ipairs(d.bodies) do
      roots[#roots + 1] = b
    end
  end
  local reachable = m:reachable(roots)
  local registry_ids = {}
  for id in pairs(reachable) do
    if m.shapes[id].type ~= "service" and m.shapes[id].type ~= "operation" then
      registry_ids[#registry_ids + 1] = id
    end
  end
  table.sort(registry_ids, function(a, b)
    return naming.local_name(a) < naming.local_name(b)
  end)

  -- type names the client definitions take for themselves
  local taken =
    { Client = "the client class", Options = "the client options", Module = "the module" }
  for _, d in ipairs(error_classes) do
    taken[d.tag .. "Error"] = "the error class " .. d.tag
  end
  for _, id in ipairs(registry_ids) do
    local name = naming.local_name(id)
    if taken[name] then
      problems[#problems + 1] = id
        .. ": its type name "
        .. spec.name
        .. "."
        .. name
        .. " is "
        .. taken[name]
    end
  end

  -- 5. shape nodes
  local nodes = {}
  for _, id in ipairs(registry_ids) do
    local node, nerr2 = shapes.node(ctx, id)
    if not node then
      problems[#problems + 1] = nerr2
    else
      nodes[#nodes + 1] = { id = id, name = naming.local_name(id), node = node }
    end
  end
  if #problems > 0 then
    return fail(problems)
  end

  -- 6. telemetry and op descriptors
  local service_telemetry
  if telemetry then
    local rules, terr = ops_mod.telemetry_rules(ctx, plan_ops)
    if not rules then
      return nil, terr
    end
    local st, sterr = ops_mod.service_telemetry(ctx, rules)
    if st == false then
      return nil, sterr
    end
    service_telemetry = st
    for _, op in ipairs(plan_ops) do
      local span, sperr = ops_mod.span(ctx, op, rules, op.http)
      if span == false then
        problems[#problems + 1] = sperr
      else
        op.span = span
      end
    end
    if #problems > 0 then
      return fail(problems)
    end
  end

  table.sort(plan_ops, function(a, b)
    return a.method_name < b.method_name
  end)

  return {
    ctx = ctx,
    model = m,
    provider = spec,
    telemetry = telemetry,
    ops = plan_ops,
    errors = error_classes,
    error_tags_set = error_tags_set,
    nodes = nodes,
    registry_ids = registry_ids,
    service_telemetry = service_telemetry,
    selected_all = args.ops == nil,
    generator_version = gen.VERSION,
  }
end

--- gen.generate(args) -> files | nil, message
function gen.generate(args)
  local plan, err = gen.plan(args)
  if not plan then
    return nil, err
  end
  local files = {}
  for name, text in pairs(writer.service(plan)) do
    files[name] = text
  end
  files["init.lua"] = writer.client(plan)
  files["types.lua"] = types_mod.render(plan)
  files["README.md"] = writer.readme(plan)
  local order = {}
  for name in pairs(files) do
    order[#order + 1] = name
  end
  table.sort(order)
  files.order = order
  return files, nil, plan
end

--- gen.write(files, dir) -> true | nil, message
-- Writes every file into dir, which must exist (the CLI creates it: the library itself
-- never runs a process).
function gen.write(files, dir)
  for _, name in ipairs(files.order) do
    local path = dir .. "/" .. name
    local f, ferr = io.open(path, "wb")
    if not f then
      return nil, "cannot write " .. path .. ": " .. tostring(ferr)
    end
    f:write(files[name])
    f:close()
  end
  return true
end

return gen
