-- The generator: a Smithy JSON model plus a provider spec -> a Lua client.
--
--   local gen = require("distilled.gen")
--   local files, err = gen.generate{
--     model = "models/neon/neon.json" | <Model>, -- path, or gen.model.load's result
--     provider = "providers/neon.lua" | <spec>,  -- path, or a spec table
--     ops = { "get_project", ... } | nil,        -- keep only these (method or model names)
--     telemetry = true,                          -- false: no span / telemetry data
--     model_name = "servers" | nil,              -- one model of a multi-model package:
--   }                                            -- module <spec.name>.servers
--   -- files = { ["init.lua"] = source, ["service.lua"] = ..., ["types.lua"] = ...,
--   --           ["README.md"] = ... }, plus files.order (the names, sorted) and
--   --           files.dirs (subdirectories: a large model has service/*.lua too)
--   gen.write(files, "clients/neon")
--
-- Port of Distilled's `generateService` (dev/src/codegen/generator.ts). Its seven steps
-- map to: model.lua (1: collect operations, named I/O), this file (2: reachability; 4:
-- errors), ops.lua (3: pagination; 6: operations), shapes.lua (5: shapes), types.lua and
-- the README (7, our equivalent of the aliases and footer). Everything that can be
-- checked is checked here; generation stops on the first batch of problems.
--
-- Packages (task 10): gen.package_layout maps a package's model files to modules (one
-- model: `<lua>`; several: `<lua>.<model>` plus the index gen.index writes), and
-- `model_name` generates one model as such a module (gen.provider.for_model).
local compat = require("distilled.compat")
local model_mod = require("distilled.gen.model")
local provider_mod = require("distilled.gen.provider")
local naming = require("distilled.gen.naming")
local shapes = require("distilled.gen.shapes")
local gen_errors = require("distilled.gen.errors")
local ops_mod = require("distilled.gen.ops")
local types_mod = require("distilled.gen.types")
local writer = require("distilled.gen.writer")
local emit = require("distilled.gen.emit")

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

-- Names a package index (gen.index) uses for itself: no model may take them.
gen.INDEX_RESERVED = { new = true, services = true }

--- gen.lua_package_name(pkg) -> the Lua module name of a Distilled package
-- (`fly-io` -> `fly_io`, `mongodb-atlas` -> `mongodb_atlas`).
function gen.lua_package_name(pkg)
  return (string.gsub(pkg, "-", "_"))
end

--- gen.lua_model_name(stem) -> the Lua name of a model, from its file name without
-- `.json` (`server_actions`, `dnsClient` -> `dns_client`, `combos-rfq` -> `combos_rfq`).
-- The rule of Distilled's tag slugs (packages/hetzner/scripts/convert.ts `toSlug`): split
-- camel boundaries, every other character run becomes `_`, lower-case. Digits stay in
-- their word (`v1alpha1`, `k8s_v1`, `s3files` are unchanged), unlike naming.snake_case.
function gen.lua_model_name(stem)
  local s = string.gsub(stem, "([a-z0-9])([A-Z])", "%1_%2")
  s = string.gsub(s, "[^A-Za-z0-9]+", "_")
  s = string.gsub(string.gsub(s, "^_+", ""), "_+$", "")
  return string.lower(s)
end

--- gen.package_layout(pkg, stems) -> layout | nil, message
-- How a package's models map to modules. One model: `clients/<lua>/`, module `<lua>`.
-- Several: `clients/<lua>/<model>/`, module `<lua>.<model>`, and an index at
-- `clients/<lua>/init.lua` (gen.index). Returns { lua, multi, models = { { stem, name,
-- module, dir } } } sorted by name; two stems with the same Lua name fail.
function gen.package_layout(pkg, stems)
  local lua = gen.lua_package_name(pkg)
  if not naming.is_identifier(lua) or string.find(lua, "%u") then
    return nil, "package " .. tostring(pkg) .. " has no Lua module name (" .. lua .. ")"
  end
  local layout = { lua = lua, multi = #stems > 1, models = {} }
  local seen, problems = {}, {}
  for _, stem in ipairs(stems) do
    local name = gen.lua_model_name(stem)
    if layout.multi and not provider_mod.is_model_name(name) then
      problems[#problems + 1] = "model " .. stem .. ": its Lua name " .. name .. " is not usable"
    elseif layout.multi and gen.INDEX_RESERVED[name] then
      problems[#problems + 1] = "model " .. stem .. " collides with the package index's " .. name
    elseif seen[name] then
      problems[#problems + 1] = "models "
        .. seen[name]
        .. " and "
        .. stem
        .. " both become "
        .. name
    end
    seen[name] = seen[name] or stem
    layout.models[#layout.models + 1] = {
      stem = stem,
      name = name,
      module = layout.multi and (lua .. "." .. name) or lua,
      dir = layout.multi and name or "",
    }
  end
  if #problems > 0 then
    return fail(problems)
  end
  table.sort(layout.models, function(a, b)
    return a.name < b.name
  end)
  return layout
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
  if args.model_name ~= nil then
    -- one model of a multi-model package: module <package>.<model> (gen.package_layout)
    if not provider_mod.is_model_name(args.model_name) then
      return nil, "model name " .. tostring(args.model_name) .. " is not a Lua model name"
    end
    if gen.INDEX_RESERVED[args.model_name] then
      return nil,
        "model "
          .. args.model_name
          .. " collides with the package index's "
          .. args.model_name
          .. " (gen.INDEX_RESERVED)"
    end
    if spec.models.skip[args.model_name] then
      return nil, "model " .. args.model_name .. " is in the provider spec's models.skip"
    end
    spec = provider_mod.for_model(spec, args.model_name)
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
    -- one model of a multi-model package: the operation may be another model's (exa's
    -- ListWebsetsItems is in exa.api only), which this model cannot check
    if not known and not spec.model_name then
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
  -- provider spec error_classes (task 13): tags of their own, usable in status_map. A
  -- model that declares an error of the same tag uses its own class for it (Vercel's
  -- PaymentRequired is in some models only); a built-in or reserved tag is an error.
  local provider_tags = {}
  for _, c in ipairs(spec.error_classes or {}) do
    provider_tags[c.tag] = true
    if builtin[c.tag] or reserved_tags[c.tag] then
      problems[#problems + 1] = "provider spec error_classes."
        .. c.tag
        .. " has the tag of "
        .. (builtin[c.tag] and "a built-in error" or ("the provider's " .. reserved_tags[c.tag]))
    end
  end
  for _, name in ipairs(spec.public_operations or {}) do
    local known = false
    for _, op in ipairs(m.operations) do
      known = known or op.name == name
    end
    if not known then
      problems[#problems + 1] = "provider spec public_operations names an unknown operation "
        .. name
    end
  end
  for status, tag in pairs(spec.status_map or {}) do
    if not error_tags_set[tag] and not builtin[tag] and not provider_tags[tag] then
      problems[#problems + 1] = "provider spec status_map["
        .. status
        .. "] names "
        .. tag
        .. ", which is neither a built-in error, a provider error class nor an error of the"
        .. " selected operations"
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

  -- type names the client definitions take for themselves: a shape with such a name is
  -- typed <Name>Shape in types.lua (naming.type_names, task 11)
  local error_tags = {}
  for i, d in ipairs(error_classes) do
    error_tags[i] = d.tag
  end
  ctx.type_names = naming.type_names(registry_ids, naming.client_type_names(error_tags))

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
  local service_files, werr = writer.service(plan)
  if not service_files then
    return nil, werr
  end
  for name, text in pairs(service_files) do
    files[name] = text
  end
  files["init.lua"] = writer.client(plan)
  if plan.provider.glue then
    -- the provider's hand-written glue travels with the client (require(MODULE .. ".glue"))
    files["glue.lua"] = plan.provider.glue.source
  end
  files["types.lua"] = types_mod.render(plan)
  files["README.md"] = writer.readme(plan)
  local order = {}
  for name in pairs(files) do
    order[#order + 1] = name
  end
  table.sort(order)
  files.order = order
  -- subdirectories the files need (a large model's service/, gen/writer.lua), sorted
  local dirs, seen = {}, {}
  for _, name in ipairs(order) do
    local dir = string.match(name, "^(.*)/[^/]*$")
    if dir and not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end
  files.dirs = dirs
  return files, nil, plan
end

--- gen.write(files, dir) -> true | nil, message
-- Writes every file into dir. dir and its subdirectories files.dirs must exist (the CLI
-- creates them: the library itself never runs a process).
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

--- gen.index(args) -> files | nil, message
-- The package index of a multi-model package, `clients/<lua>/init.lua` (plus README.md):
--
--   args = { provider = <spec or path>, services = { { name = "servers", title =
--            "HetznerServers", operations = 6, source = "servers.json", hash = "..." } } }
--
-- What it returns at run time (the index loads nothing until a service is used):
--   index.services         the service names, sorted
--   index.<name>           the service's client class, require("<lua>.<name>") on first use
--   index.new(options)     a table of clients, one per service, each built on first use
--                          as index.<name>.new(options) (so they share host and secrets)
function gen.index(args)
  if type(args) ~= "table" or type(args.services) ~= "table" then
    error("distilled.gen.index: expected { provider, services }", 2)
  end
  local spec, err = args.provider, nil
  if type(spec) == "string" then
    spec, err = provider_mod.load(spec)
  elseif type(spec) == "table" and not spec.__validated then
    spec, err = provider_mod.validate(spec)
  end
  if not spec then
    return nil, err
  end
  local services = {}
  for _, svc in ipairs(args.services) do
    services[#services + 1] = svc
  end
  if #services == 0 then
    return nil, "package " .. spec.name .. ": no service to index"
  end
  table.sort(services, function(a, b)
    return a.name < b.name
  end)
  local problems = {}
  for i, svc in ipairs(services) do
    if not provider_mod.is_model_name(svc.name) then
      problems[#problems + 1] = "service " .. tostring(svc.name) .. " is not a Lua model name"
    elseif gen.INDEX_RESERVED[svc.name] then
      problems[#problems + 1] = "service " .. svc.name .. " collides with the index's own field"
    elseif i > 1 and services[i - 1].name == svc.name then
      problems[#problems + 1] = "service " .. svc.name .. " is listed twice"
    end
  end
  if #problems > 0 then
    return fail(problems)
  end
  local name, title = spec.name, spec.title
  local function field(n)
    return naming.is_identifier(n) and ("." .. n) or ("[" .. emit.string(n) .. "]")
  end
  local total = 0
  for _, svc in ipairs(services) do
    total = total + (svc.operations or 0)
  end
  local example = services[1]
  local class_title = example.title or "Service"

  local b = emit.buffer()
  b:line(
    "-- "
      .. title
      .. ": the package index ("
      .. #services
      .. " services, "
      .. total
      .. " operations)."
  )
  b:line("--")
  b:line(
    "-- Generated by distilled-lua (generator "
      .. gen.VERSION
      .. ") with provider spec "
      .. name
      .. "."
  )
  b:line("-- Do not edit: regenerate with bin/distilled-lua package.")
  b:line("--")
  b:lines_of(
    emit.comment(
      "Each service is its own client class in "
        .. name
        .. "/<service>/, loaded on first use. See README.md next to this file."
    )
  )
  b:line("--")
  b:line("--   local " .. name .. ' = require("' .. name .. '")')
  b:line(
    "--   local "
      .. class_title
      .. " = "
      .. name
      .. field(example.name)
      .. ' -- = require("'
      .. name
      .. "."
      .. example.name
      .. '")'
  )
  b:line("--   local client = " .. class_title .. ".new({ host = ... })")
  b:line("--   -- or one set of options for every service, each client built on first use:")
  b:line("--   local clients = " .. name .. ".new({ host = ... })")
  b:line("--   clients" .. field(example.name) .. ":<operation>({ ... })")
  b:line("local MODULE = ... or " .. emit.string(name))
  b:blank()
  b:line("local index = {}")
  b:blank()
  b:lines_of(emit.comment('The services, sorted: index[name] is require(MODULE .. "." .. name).'))
  b:line("index.services = {")
  for _, svc in ipairs(services) do
    b:line("  " .. emit.string(svc.name) .. ",")
  end
  b:line("}")
  b:blank()
  b:line("local known = {}")
  b:line("for _, service in ipairs(index.services) do")
  b:line("  known[service] = true")
  b:line("end")
  b:blank()
  b:lines_of(
    emit.comment(
      "index.new(options) -> clients: clients[name] is index[name].new(options), built on "
        .. "first use. Unknown names are nil."
    )
  )
  b:line("function index.new(options)")
  b:line("  local clients = {}")
  b:line("  return setmetatable(clients, {")
  b:line("    __index = function(_, service)")
  b:line("      if not known[service] then")
  b:line("        return nil")
  b:line("      end")
  b:line("      local client = index[service].new(options)")
  b:line("      rawset(clients, service, client)")
  b:line("      return client")
  b:line("    end,")
  b:line("  })")
  b:line("end")
  b:blank()
  b:line("return setmetatable(index, {")
  b:line("  __index = function(_, service)")
  b:line("    if not known[service] then")
  b:line("      return nil")
  b:line("    end")
  b:line('    local class = require(MODULE .. "." .. service)')
  b:line("    rawset(index, service, class)")
  b:line("    return class")
  b:line("  end,")
  b:line("})")

  local r = {}
  local function add(line)
    r[#r + 1] = line or ""
  end
  add("# " .. title .. " clients (generated)")
  add()
  add(
    "Generated by distilled-lua (generator "
      .. gen.VERSION
      .. ") with the provider spec `"
      .. name
      .. "`."
  )
  add("Do not edit; regenerate with `bin/distilled-lua package`.")
  add()
  add(
    "One client class per service ("
      .. #services
      .. " services, "
      .. total
      .. " operations), each in `"
      .. name
      .. "/<service>/`"
  )
  add('with its own README.md. `require("' .. name .. '")` is an index that loads a service on')
  add("first use.")
  add()
  add("```lua")
  add("local " .. name .. ' = require("' .. name .. '")')
  add(
    "local "
      .. class_title
      .. " = "
      .. name
      .. field(example.name)
      .. ' -- require("'
      .. name
      .. "."
      .. example.name
      .. '")'
  )
  add("local client = " .. class_title .. '.new({ host = require("distilled.host.popen")() })')
  add()
  add("-- one set of options for every service; each client is built on first use")
  add("local clients = " .. name .. '.new({ host = require("distilled.host.popen")() })')
  add("```")
  add()
  add("`" .. name .. ".services` lists the service names.")
  add()
  add("| Service | Module | Operations | Model |")
  add("| --- | --- | --- | --- |")
  for _, svc in ipairs(services) do
    add(
      "| ["
        .. svc.name
        .. "]("
        .. svc.name
        .. "/README.md) | `"
        .. name
        .. "."
        .. svc.name
        .. "` | "
        .. tostring(svc.operations or "?")
        .. " | `"
        .. tostring(svc.source or "?")
        .. "` ("
        .. tostring(svc.hash or "?")
        .. ") |"
    )
  end
  local files = {
    ["init.lua"] = b:text(),
    ["README.md"] = compat.concat(r, "\n") .. "\n",
    order = { "README.md", "init.lua" },
  }
  return files
end

return gen
