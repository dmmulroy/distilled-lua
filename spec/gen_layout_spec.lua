-- Task 10: packages with several models. Provider spec `models` keys, module names, the
-- package layout, one model as module <pkg>.<model>, the package index (lazy loading,
-- index.new), `bin/distilled-lua package`, and the committed Hetzner client (30 models)
-- over the scripted transport.
local t = require("spec.harness")
local gen = require("distilled.gen")
local provider = require("distilled.gen.provider")
local compat = require("distilled.compat")
local json = require("distilled.json")
local testing = require("distilled.testing")
local fx = require("verify.lib.gen_fixture")

local rex_api = rawget(_G, "rex")

local function bad(overrides, pattern)
  local spec, err = provider.validate(fx.provider(overrides))
  t.eq(spec, nil)
  t.match(err, pattern, true)
end

t.describe("gen.provider: models (multi-model packages)", function()
  t.it("defaults to no skip and no override", function()
    local spec = provider.validate(fx.provider())
    t.same(spec.models, { skip = {}, override = {} })
  end)

  t.it("accepts skip and override; a URL string replaces only the default", function()
    local spec, err = provider.validate(fx.provider({
      models = {
        skip = { "pricing" },
        override = {
          servers = { title = "ExServers", base_url = "https://servers.example.test" },
          volumes = { base_url = { env = "EX_VOLUMES_URL" } },
        },
      },
    }))
    t.truthy(spec, err)
    t.same(spec.models.skip, { pricing = true })
    t.same(spec.models.override.servers, {
      title = "ExServers",
      base_url = {
        default = "https://servers.example.test",
        option = "base_url",
        env = "EX_BASE_URL",
      },
    })
    t.same(spec.models.override.volumes.base_url, {
      default = "https://api.example.test/v1",
      option = "base_url",
      env = "EX_VOLUMES_URL",
    })
  end)

  t.it("rejects unknown keys and bad entries, naming them", function()
    bad(
      { models = { skipped = {} } },
      "provider spec models: unknown key skipped (allowed: override, skip)"
    )
    bad({ models = "all" }, "models must be { skip = { ... }, override = { ... } }")
    bad({ models = { skip = "x" } }, "models.skip must be a list of model names")
    bad({ models = { skip = { x = true } } }, "models.skip must be a list of model names")
    bad({ models = { skip = { "Servers" } } }, "models.skip[1] must be a model name")
    bad({ models = { skip = { "a", "a" } } }, "models.skip lists a twice")
    bad({ models = { override = { ["Bad-Name"] = {} } } }, "key Bad-Name is not a model name")
    bad({ models = { override = { a = "x" } } }, "models.override.a must be a table")
    bad({ models = { override = { a = { colour = 1 } } } }, "models.override.a: unknown key colour")
    bad(
      { models = { override = { a = { title = "Ex Servers" } } } },
      "title must be a Lua identifier"
    )
    bad(
      { models = { override = { a = { base_url = "ftp://x" } } } },
      "models.override.a.base_url.default must be an http(s) URL"
    )
    bad({ models = { override = { a = { base_url = "https://x.test/" } } } }, "must not end with /")
    bad(
      { models = { override = { a = { base_url = { option = "api_key" } } } } },
      "models.override.a: auth.from and base_url.option are the same option"
    )
    bad(
      { models = { skip = { "a" }, override = { a = {} } } },
      "models.override.a: the model is also in models.skip"
    )
  end)

  t.it("check_models: skip and override must name models of the package", function()
    local spec = provider.validate(fx.provider({
      models = { skip = { "servrs" }, override = { volume = {} } },
    }))
    local ok, err = provider.check_models(spec, { "servers", "volumes", "zones" })
    t.eq(ok, nil)
    t.match(
      err,
      "models.skip names servrs, which is not a model of the package; nearest: servers",
      true
    )
    t.match(
      err,
      "models.override names volume, which is not a model of the package; nearest: volumes",
      true
    )
    t.eq(provider.check_models(spec, { "servrs", "volume" }), true)
  end)

  t.it("for_model: module name, class name, the model's override", function()
    local spec = provider.validate(fx.provider({
      title = "Ex.io",
      models = { override = { servers = { base_url = "https://s.example.test" } } },
    }))
    local s = provider.for_model(spec, "server_actions")
    t.eq(s.name, "ex.server_actions")
    t.eq(s.package, "ex")
    t.eq(s.model_name, "server_actions")
    t.eq(s.title, "ExioServerActions")
    t.eq(s.base_url, spec.base_url)
    t.eq(spec.name, "ex", "the package spec is not changed")
    local v = provider.for_model(spec, "servers")
    t.eq(v.base_url.default, "https://s.example.test")
    t.eq(v.base_url.env, "EX_BASE_URL")
    t.eq(provider.for_model(spec, "v2_api").title, "ExioV2Api")
    t.raises(function()
      provider.for_model(fx.provider(), "servers")
    end, "expected a validated spec")
    t.raises(function()
      provider.for_model(spec, "Servers")
    end, "bad model name")
  end)
end)

t.describe("gen: package and model names", function()
  t.it("a package's Lua name replaces - with _", function()
    t.eq(gen.lua_package_name("fly-io"), "fly_io")
    t.eq(gen.lua_package_name("mongodb-atlas"), "mongodb_atlas")
    t.eq(gen.lua_package_name("neon"), "neon")
  end)

  t.it("a model's Lua name follows Distilled's slug rule", function()
    t.eq(gen.lua_model_name("server_actions"), "server_actions")
    t.eq(gen.lua_model_name("dnsClient"), "dns_client")
    t.eq(gen.lua_model_name("redisCloud"), "redis_cloud")
    t.eq(gen.lua_model_name("combos-rfq"), "combos_rfq")
    t.eq(gen.lua_model_name("trigger-dev"), "trigger_dev")
    -- digits stay in their word (naming.snake_case would split these)
    t.eq(gen.lua_model_name("autoscaling_v1alpha2"), "autoscaling_v1alpha2")
    t.eq(gen.lua_model_name("k8s_v1"), "k8s_v1")
    t.eq(gen.lua_model_name("s3files"), "s3files")
    t.eq(gen.lua_model_name("resource-explorer-2"), "resource_explorer_2")
  end)

  t.it("one model: clients/<lua>/, module <lua>", function()
    local l = gen.package_layout("redis-cloud", { "redisCloud" })
    t.same(l, {
      lua = "redis_cloud",
      multi = false,
      models = { { stem = "redisCloud", name = "redis_cloud", module = "redis_cloud", dir = "" } },
    })
  end)

  t.it("several models: <lua>.<model> in <lua>/<model>/, sorted by Lua name", function()
    local l = gen.package_layout("fly-io", { "volumes", "apps", "dnsRecords" })
    t.eq(l.multi, true)
    t.eq(l.lua, "fly_io")
    t.same(l.models[1], { stem = "apps", name = "apps", module = "fly_io.apps", dir = "apps" })
    t.eq(l.models[2].module, "fly_io.dns_records")
    t.eq(l.models[3].dir, "volumes")
  end)

  t.it("fails early on two models with one Lua name and on the index's own names", function()
    local l, err = gen.package_layout("p", { "foo-bar", "foo_bar" })
    t.eq(l, nil)
    t.match(err, "models foo-bar and foo_bar both become foo_bar", true)
    l, err = gen.package_layout("p", { "new", "services", "x" })
    t.eq(l, nil)
    t.match(err, "model new collides with the package index's new", true)
    t.match(err, "model services collides with the package index's services", true)
    -- a single model may have any name: it is not reached through an index
    t.truthy(gen.package_layout("p", { "new" }))
  end)
end)

t.describe("gen.generate: one model of a multi-model package", function()
  local m = fx.model()
  local spec = fx.provider({
    models = {
      override = { things = { base_url = "https://things.example.test", title = "ExThings" } },
    },
  })

  t.it("names the module <pkg>.<model> everywhere it appears", function()
    local files, err = gen.generate({ model = m, provider = spec, model_name = "things" })
    t.truthy(files, err)
    t.match(files["init.lua"], 'local MODULE = ... or "ex.things"', true)
    t.match(files["init.lua"], 'local ExThings = require("ex.things")', true)
    t.match(files["init.lua"], 'default = "https://things.example.test"', true)
    t.match(files["service.lua"], 'name = "ex.things",', true)
    t.match(files["types.lua"], "---@class ex.things.Client", true)
    t.match(files["README.md"], 'local ExThings = require("ex.things")', true)
    t.no_match(files["init.lua"], "https://api.example.test/v1", true)
  end)

  t.it("without model_name the module is the spec's name (single-model packages)", function()
    local files = gen.generate({ model = m, provider = fx.provider() })
    t.match(files["init.lua"], 'local MODULE = ... or "ex"', true)
    t.match(files["service.lua"], 'name = "ex",', true)
  end)

  t.it("the generated client loads as its module and uses the model's base URL", function()
    local files = gen.generate({ model = m, provider = spec, model_name = "things" })
    local svc = fx.load(files["service.lua"], "ex.things.service")
    local Class = fx.load(files["init.lua"], "ex.things", { ["ex.things.service"] = svc })
    local host = testing.host({ responses = { { status = 200, body = { id = "t1" } } } })
    local c = Class.new({ host = host, api_key = "k" })
    local _, err = c:get_thing({ thing_id = "t1" })
    t.eq(err, nil)
    t.eq(host.requests[1].url, "https://things.example.test/things/t1")
  end)

  t.it("refuses a skipped model, a reserved name and a bad name", function()
    local skip = fx.provider({ models = { skip = { "things" } } })
    local files, err = gen.generate({ model = m, provider = skip, model_name = "things" })
    t.eq(files, nil)
    t.match(err, "model things is in the provider spec's models.skip", true)
    files, err = gen.generate({ model = m, provider = fx.provider(), model_name = "new" })
    t.eq(files, nil)
    t.match(err, "collides with the package index's new", true)
    files, err = gen.generate({ model = m, provider = fx.provider(), model_name = "Things" })
    t.eq(files, nil)
    t.match(err, "is not a Lua model name", true)
  end)
end)

t.describe("gen.index: the package index", function()
  local services = {
    { name = "zones", title = "ExZones", operations = 2, source = "zones.json", hash = "h2" },
    { name = "end", title = "ExEnd", operations = 1, source = "end.json", hash = "h3" },
    { name = "apps", title = "ExApps", operations = 3, source = "apps.json", hash = "h1" },
  }

  -- load the index with fake service modules in package.loaded; returns index, made
  local function load_index(files)
    local made = {}
    local loads = {}
    local fakes = {}
    for _, s in ipairs(services) do
      fakes["ex." .. s.name] = {
        new = function(opts)
          made[#made + 1] = { service = s.name, opts = opts }
          return { service = s.name }
        end,
      }
    end
    -- package.preload counts the requires; package.loaded must not hold them yet
    local saved = {}
    for name, value in pairs(fakes) do
      saved[name] = package.preload[name]
      package.preload[name] = function()
        loads[#loads + 1] = name
        return value
      end
      package.loaded[name] = nil
    end
    local index = fx.load(files["init.lua"], "ex")
    return index,
      made,
      loads,
      function()
        for name in pairs(fakes) do
          package.preload[name] = saved[name]
          package.loaded[name] = nil
        end
      end
  end

  t.it("lists the services sorted and loads each on first use only", function()
    local files, err = gen.index({ provider = fx.provider(), services = services })
    t.truthy(files, err)
    t.same(files.order, { "README.md", "init.lua" })
    local index, _, loads, restore = load_index(files)
    t.same(index.services, { "apps", "end", "zones" })
    t.eq(#loads, 0, "requiring the index loads no service")
    local apps = index.apps
    t.eq(apps, package.loaded["ex.apps"])
    t.eq(index.apps, apps)
    t.same(loads, { "ex.apps" })
    t.eq(index["end"], package.loaded["ex.end"], "a keyword is reached with brackets")
    t.eq(index.nope, nil)
    t.same(loads, { "ex.apps", "ex.end" })
    restore()
  end)

  t.it("index.new builds each client on first use with the shared options", function()
    local files = gen.index({ provider = fx.provider(), services = services })
    local index, made, loads, restore = load_index(files)
    local opts = { api_key = "k" }
    local clients = index.new(opts)
    t.eq(#made, 0)
    t.eq(#loads, 0)
    local z = clients.zones
    t.same(z, { service = "zones" })
    t.eq(clients.zones, z, "built once")
    t.eq(#made, 1)
    t.eq(made[1].opts, opts)
    t.eq(clients.nope, nil)
    t.eq(#made, 1)
    restore()
  end)

  t.it("is deterministic, formatted text with the service table in the README", function()
    local a = gen.index({ provider = fx.provider(), services = services })
    local b = gen.index({ provider = fx.provider(), services = services })
    t.eq(a["init.lua"], b["init.lua"])
    t.match(a["init.lua"], "-- Ex: the package index (3 services, 6 operations).", true)
    t.match(a["README.md"], "| [apps](apps/README.md) | `ex.apps` | 3 | `apps.json` (h1) |", true)
    t.match(a["README.md"], 'local ExApps = ex.apps -- require("ex.apps")', true)
    for line in string.gmatch(a["init.lua"], "([^\n]*)\n") do
      t.truthy(#line <= 100, line)
    end
  end)

  t.it("fails on no service, a reserved or duplicate name", function()
    local files, err = gen.index({ provider = fx.provider(), services = {} })
    t.eq(files, nil)
    t.match(err, "no service to index", true)
    files, err = gen.index({
      provider = fx.provider(),
      services = { { name = "new" }, { name = "a" }, { name = "a" } },
    })
    t.eq(files, nil)
    t.match(err, "service new collides with the index's own field", true)
    t.match(err, "service a is listed twice", true)
    t.raises(function()
      gen.index({ provider = fx.provider() })
    end, "expected { provider, services }")
  end)
end)

t.describe("bin/distilled-lua package", function()
  if rex_api then
    t.pending("package CLI: needs io.popen (lua and luajit only)")
    return
  end
  local function run(cmd)
    local p = io.popen(cmd .. ' 2>&1; echo "exit:$?"')
    local out = p:read("*a")
    p:close()
    local code = tonumber(string.match(out, "exit:(%d+)%s*$"))
    return (string.gsub(out, "exit:%d+%s*$", "")), code
  end
  local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end
  local bin = "lua " .. t.root .. "/bin/distilled-lua"
  local SPEC = [[
return {
  name = "ex",
  base_url = "https://api.example.test/v1",
  auth = { kind = "bearer", from = "api_key", env = "EX_API_KEY" },
  unknown_tag = "UnknownExError",
  parse_tag = "ExParseError",
  models = { %s },
}
]]

  local function setup(models_key)
    local dir = os.tmpname()
    os.remove(dir)
    run("mkdir -p " .. dir .. "/models/ex")
    write(dir .. "/models/ex/things.json", fx.text())
    write(dir .. "/models/ex/moreThings.json", fx.text())
    write(
      dir .. "/models/ex/broken.json",
      fx.text({ replace = { { '"uri": "/things/{thing_id}"', '"uri": "/things/{nope}"' } } })
    )
    write(
      dir .. "/models/ex/hooks.json",
      '{"smithy":"2.0","shapes":{"ex.hooks#Svc":{"type":"service","version":"1"}}}'
    )
    write(dir .. "/ex.lua", string.format(SPEC, models_key or ""))
    return dir
  end
  local function package_cmd(dir, extra)
    return bin
      .. " package --models "
      .. dir
      .. "/models/ex --provider "
      .. dir
      .. "/ex.lua --out "
      .. dir
      .. "/clients/ex"
      .. (extra or "")
  end

  t.it("reports each model, writes the good ones and the index, exits 1 on a failure", function()
    local dir = setup()
    local out, code = run(package_cmd(dir))
    t.eq(code, 1, out)
    t.match(out, "FAIL ex/broken: ", true)
    t.match(out, "ok   ex/moreThings: 5 operations", true)
    t.match(out, "skip ex/hooks: no operations", true)
    t.match(out, "ok   ex/things: 5 operations", true)
    t.match(out, "package ex: 2 ok, 1 failed, 1 skipped; 10 operations", true)
    t.truthy(read(dir .. "/clients/ex/things/service.lua"))
    t.truthy(read(dir .. "/clients/ex/more_things/init.lua"))
    t.eq(read(dir .. "/clients/ex/broken/init.lua"), nil)
    local index = read(dir .. "/clients/ex/init.lua")
    t.match(index, '  "more_things",\n  "things",\n}', true)
    t.no_match(index, '"broken"', true)
    t.eq(read(dir .. "/clients/ex.staging/init.lua"), nil, "no staging dir left")
    run("rm -rf " .. dir)
  end)

  t.it("models.skip skips; a stale skip name fails before writing anything", function()
    local dir = setup('skip = { "broken" }')
    local out, code = run(package_cmd(dir))
    t.eq(code, 0, out)
    t.match(out, "skip ex/broken: models.skip in the provider spec", true)
    t.match(out, "package ex: 2 ok, 0 failed, 2 skipped", true)
    run("rm -rf " .. dir)
    dir = setup('skip = { "brokn" }')
    out, code = run(package_cmd(dir))
    t.eq(code, 1)
    t.match(
      out,
      "models.skip names brokn, which is not a model of the package; nearest: broken",
      true
    )
    t.eq(read(dir .. "/clients/ex/init.lua"), nil)
    run("rm -rf " .. dir)
  end)

  t.it("replaces a generated package wholesale and refuses any other directory", function()
    local dir = setup('skip = { "broken" }')
    run("mkdir -p " .. dir .. "/clients/ex/gone && touch " .. dir .. "/clients/ex/gone/x")
    local out, code = run(package_cmd(dir))
    t.eq(code, 1)
    t.match(out, "exists and is not a generated package; refusing to replace it", true)
    run("rm -rf " .. dir .. "/clients/ex")
    out, code = run(package_cmd(dir))
    t.eq(code, 0, out)
    run("mkdir -p " .. dir .. "/clients/ex/gone")
    out, code = run(package_cmd(dir, " --only things --quiet"))
    t.eq(code, 0, out)
    t.no_match(out, "ok   ", true)
    t.eq(read(dir .. "/clients/ex/more_things/init.lua"), nil, "replaced, not merged")
    t.match(read(dir .. "/clients/ex/init.lua"), 'index.services = {\n  "things",\n}', true)
    run("rm -rf " .. dir)
  end)

  t.it("a package with one model is written flat, as before", function()
    local dir = os.tmpname()
    os.remove(dir)
    run("mkdir -p " .. dir .. "/models/ex")
    write(dir .. "/models/ex/ex.json", fx.text())
    write(dir .. "/ex.lua", string.format(SPEC, ""))
    local out, code = run(package_cmd(dir))
    t.eq(code, 0, out)
    t.match(read(dir .. "/clients/ex/init.lua"), 'local MODULE = ... or "ex"', true)
    t.truthy(read(dir .. "/clients/ex/service.lua"))
    run("rm -rf " .. dir)
  end)

  t.it("generate --model-name writes one model as <pkg>.<model>", function()
    local dir = setup()
    local out, code = run(
      bin
        .. " generate --model "
        .. dir
        .. "/models/ex/things.json --provider "
        .. dir
        .. "/ex.lua --out "
        .. dir
        .. "/one --model-name things"
    )
    t.eq(code, 0, out)
    t.match(read(dir .. "/one/init.lua"), 'local MODULE = ... or "ex.things"', true)
    run("rm -rf " .. dir)
  end)
end)

t.describe("hetzner client (clients/hetzner/, 30 models)", function()
  package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path
  local BASE = "https://api.hetzner.cloud/v1"
  local KEY = "hcloud-SPEC-FAKE-TOKEN"

  local function servers(responses, extra)
    local host = testing.host({ responses = responses, env = {} })
    local opts = { host = host, token = KEY }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    return require("hetzner").servers.new(opts), host
  end

  t.it("the index lists the 30 services and loads them lazily", function()
    local hetzner = require("hetzner")
    t.eq(#hetzner.services, 30)
    t.eq(hetzner.services[1], "actions")
    t.eq(hetzner.servers, require("hetzner.servers"))
  end)

  -- servers.ts getServer: GET /servers/{id}, bearer token, version in the base URL
  t.it("get_server sends GET <base>/servers/{id} with the bearer token", function()
    local c, host = servers({ { status = 200, body = { server = { id = 42, name = "web" } } } })
    local out, err = c:get_server({ id = 42 })
    t.eq(err, nil)
    t.eq(out.server.name, "web")
    local req = host.requests[1]
    t.eq(req.method, "GET")
    t.eq(req.url, BASE .. "/servers/42")
    t.eq(req.headers.authorization, "Bearer " .. KEY)
  end)

  -- protocol.ts errorEnvelope: { error = { code, message } }
  t.it("reads the error envelope: a 404 is NotFound with Hetzner's code and message", function()
    local c = servers({
      { status = 404, body = { error = { code = "not_found", message = "server not found" } } },
    })
    local out, err = c:get_server({ id = 1 })
    t.eq(out, nil)
    t.eq(err.tag, "NotFound")
    t.eq(err.code, "not_found")
    t.eq(err.message, "server not found")
    t.eq(err.status, 404)
  end)

  t.it("a status nothing maps is UnknownHetznerError (405 until task 13)", function()
    local c = servers({
      { status = 405, body = { error = { code = "method_not_allowed", message = "nope" } } },
    })
    local _, err = c:get_server({ id = 1 })
    t.eq(err.tag, "UnknownHetznerError")
    t.eq(err.code, "method_not_allowed")
  end)

  t.it("a model error matcher wins: 403 'server limit' is ServerLimitExceeded", function()
    local c = servers({
      {
        status = 403,
        body = { error = { code = "resource_limit_exceeded", message = "server limit reached" } },
      },
    })
    local _, err = c:create_server({ name = "x", server_type = "cx22", image = "ubuntu-24.04" })
    t.eq(err.tag, "ServerLimitExceeded")
  end)

  t.it("retries a 429 and then succeeds", function()
    local c, host = servers({
      { status = 429, body = { error = { code = "rate_limit_exceeded", message = "slow" } } },
      { status = 200, body = { server = { id = 7 } } },
    })
    local out, err = c:get_server({ id = 7 })
    t.eq(err, nil)
    t.eq(out.server.id, 7)
    t.eq(#host.requests, 2)
    t.eq(#host.sleeps, 1)
  end)

  -- convert.ts paginationFor: page mode, page / per_page, meta.pagination.next_page
  t.it("list_servers_items walks pages until next_page is null", function()
    local function page(ids, next_page)
      local list = {}
      for i, id in ipairs(ids) do
        list[i] = { id = id, name = "s" .. id }
      end
      return {
        status = 200,
        body = {
          servers = json.array(list),
          meta = { pagination = { page = 1, next_page = next_page or json.null } },
        },
      }
    end
    local c, host = servers({ page({ 1, 2 }, 2), page({ 3 }) })
    local items, err = c:list_servers_items({ per_page = 2 }):collect()
    t.eq(err, nil)
    t.eq(#items, 3)
    t.eq(items[3].id, 3)
    t.eq(#host.requests, 2)
    -- pagination.ts paginatePageNumber: the first request carries page=1
    t.match(host.requests[1].url, "[?&]page=1")
    t.match(host.requests[1].url, "per_page=2", true)
    t.match(host.requests[2].url, "[?&]page=2")
  end)

  t.it("an empty first page yields no items and stops", function()
    local c, host = servers({
      {
        status = 200,
        body = { servers = json.array({}), meta = { pagination = { next_page = json.null } } },
      },
    })
    local items, err = c:list_servers_items({}):collect()
    t.eq(err, nil)
    t.eq(#items, 0)
    t.eq(#host.requests, 1)
  end)

  t.it("a missing token fails the call with ConfigError naming HCLOUD_TOKEN", function()
    local host = testing.host({ responses = {}, env = {} })
    local c = require("hetzner.servers").new({ host = host })
    local _, err = c:get_server({ id = 1 })
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "token")
    t.match(err.message, "HCLOUD_TOKEN", true)
    t.eq(#host.requests, 0)
  end)

  t.it("HCLOUD_ENDPOINT overrides the base URL; hetzner.new shares the options", function()
    local host = testing.host({
      responses = {
        { status = 200, body = { server = { id = 1 } } },
        { status = 200, body = { volume = { id = 2 } } },
      },
      env = { HCLOUD_ENDPOINT = "http://127.0.0.1:9/v1" },
    })
    local clients = require("hetzner").new({ host = host, token = KEY })
    local _, err = clients.servers:get_server({ id = 1 })
    t.eq(err, nil)
    _, err = clients.volumes:get_volume({ id = 2 })
    t.eq(err, nil)
    t.eq(host.requests[1].url, "http://127.0.0.1:9/v1/servers/1")
    t.eq(host.requests[2].url, "http://127.0.0.1:9/v1/volumes/2")
    t.eq(host.requests[2].headers.authorization, "Bearer " .. KEY)
  end)

  t.it("never puts the token in an error", function()
    local c =
      servers({ { status = 401, body = { error = { code = "unauthorized", message = "bad" } } } })
    local _, err = c:get_server({ id = 1 })
    t.eq(err.tag, "Unauthorized")
    local ok, text = compat.pcall(json.encode, {
      message = err.message,
      code = err.code,
      body = err.body,
      headers = err.headers,
    })
    t.truthy(ok)
    t.no_match(text, KEY, true)
  end)
end)
