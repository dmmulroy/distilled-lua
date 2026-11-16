local t = require("spec.harness")
local fx = require("verify.lib.gen_fixture")

local rex_api = rawget(_G, "rex")

t.describe("gen: output files", function()
  local files, _, plan = fx.generate()

  t.it("writes init.lua, service.lua, types.lua and README.md", function()
    t.same(files.order, { "README.md", "init.lua", "service.lua", "types.lua" })
  end)

  t.it("is deterministic: the same input gives byte-identical files", function()
    local again = fx.generate()
    for _, name in ipairs(files.order) do
      t.eq(again[name], files[name], name)
    end
  end)

  t.it("names the model hash in a header and carries no timestamp", function()
    for _, name in ipairs({ "init.lua", "service.lua", "types.lua" }) do
      t.match(files[name], plan.model.hash, true)
      t.no_match(files[name], "%d%d%d%d%-%d%d%-%d%d")
      t.no_match(files[name], "%d%d:%d%d")
    end
    t.match(files["README.md"], plan.model.hash, true)
  end)

  t.it("keeps every Lua line within 100 columns except long data strings", function()
    for _, name in ipairs({ "init.lua", "service.lua" }) do
      for line in string.gmatch(files[name], "([^\n]*)\n") do
        if #line > 100 then
          t.match(line, '^%s*[%w_]+ = ".*",$')
        end
      end
    end
  end)

  t.it("init.lua hands Client.define the service, a REST protocol and the options", function()
    local seen = {}
    local fake_rest = {
      new = function(args)
        seen.rest = args
        return { kind = "rest" }
      end,
      bearer = function(option)
        return "bearer:" .. option
      end,
    }
    local fake_client = {
      define = function(args)
        seen.define = args
        return { new = function() end }
      end,
    }
    local svc = fx.load(files["service.lua"], "ex.service")
    local class = fx.load(files["init.lua"], "ex", {
      ["distilled.client"] = fake_client,
      ["distilled.protocol.rest"] = fake_rest,
      ["ex.service"] = svc,
    })
    t.eq(type(class.new), "function")
    t.eq(seen.define.service, svc)
    t.same(seen.define.protocol, { kind = "rest" })
    t.same(seen.define.options, {
      api_key = { secret = true, env = "EX_API_KEY", required = true },
      base_url = { default = "https://api.example.test/v1", env = "EX_BASE_URL" },
    })
    t.eq(seen.rest.headers, "bearer:api_key")
    t.eq(seen.rest.unknown_tag, "UnknownExError")
    t.eq(seen.rest.parse_tag, "ExParseError")
    t.eq(seen.rest.base_url({ base_url = "https://override.test" }), "https://override.test")
  end)

  t.it("header auth, an error envelope and a classify module reach rest.new", function()
    local f2 = assert(fx.generate({
      provider = fx.provider({
        auth = { kind = "header", from = "token", header = "X-Api-Key" },
        error_envelope = { code = "/error/code", message = "/error/message" },
        error_fields_at = "/error",
        status_map = { [418] = "Teapot" },
        classify_error = "ex_extra.classify",
      }),
    }))
    local seen = {}
    local classify = function() end
    fx.load(f2["init.lua"], "ex", {
      ["distilled.client"] = {
        define = function(args)
          seen.define = args
          return {}
        end,
      },
      ["distilled.protocol.rest"] = {
        new = function(args)
          seen.rest = args
          return {}
        end,
        header = function(name, option)
          return "header:" .. name .. ":" .. option
        end,
      },
      ["ex.service"] = {},
      ["ex_extra.classify"] = classify,
    })
    t.eq(seen.rest.headers, "header:x-api-key:token")
    t.eq(seen.rest.classify_error, classify)
    t.eq(seen.rest.error_fields_at, "/error")
    t.same(seen.rest.status_map, { [418] = "Teapot" })
    t.same(
      seen.rest.error_envelope({ error = { code = "E1", message = "bad" } }),
      { code = "E1", message = "bad" }
    )
    t.truthy(seen.define.options.token.secret)
  end)

  t.it("types.lua declares classes, aliases, and a documented method per operation", function()
    local ty = files["types.lua"]
    t.match(ty, "^%-%-%-@meta\n")
    t.match(ty, "---@class ex.Thing\n---@field id string The id.\n", true)
    t.match(ty, "---@field displayName? string\n", true)
    t.match(ty, "---@field secret? distilled.Secret\n", true)
    t.match(ty, "---@field kind? ex.Kind|distilled.Null\n", true)
    t.match(ty, "---@field verbose? boolean\n", true)
    t.match(ty, '---@alias ex.Kind "a"|"b"\n', true)
    t.match(ty, "---@alias ex.Size 1|2\n", true)
    t.match(ty, "---@alias ex.Shape ex.Circle|ex.Square\n", true)
    t.match(ty, "---@alias ex.TagList string[]\n", true)
    t.match(ty, "---@alias ex.LabelMap { [string]: string }\n", true)
    t.match(ty, "---@class ex.Meta\n---@field note? string\n---@field [string] any\n", true)
    t.match(
      ty,
      "---Get a thing\n---\n---Returns the thing.\n---\n---`GET /things/{thing_id}`\n",
      true
    )
    t.match(ty, "---@param input ex.GetThingRequest\n---@return ex.ThingResponse? value\n", true)
    t.match(ty, "---@param input? ex.ListNamesRequest\n---@return ex.TagList? value\n", true)
    t.match(
      ty,
      "---@return string? value\n---@return distilled.Error? err\nfunction Client:get_blob(input) end",
      true
    )
    t.match(
      ty,
      "---@return distilled.Iterator<ex.ListThingsResponse>\nfunction Client:list_things_pages(input) end",
      true
    )
    t.match(
      ty,
      "---@return distilled.Iterator<ex.Thing>\nfunction Client:list_things_items(input) end",
      true
    )
    t.match(ty, "---@class ex.ThrottledError: distilled.Error\n", true)
    t.match(ty, "---@field api_key? string|distilled.Secret|fun(host: table)", true)
  end)

  t.it("types.lua is valid Lua", function()
    local compat = require("distilled.compat")
    t.truthy(compat.load(files["types.lua"], "=types"))
  end)

  t.it("README lists the operations with one-line docs and the errors", function()
    local md = files["README.md"]
    t.match(md, "| `get_thing` | `GET /things/{thing_id}` | Get a thing |", true)
    t.match(md, "| `list_things` (+ `_pages`, `_items`) | `GET /things` |", true)
    t.match(md, "| `Throttled` | ThrottlingError, RetryableError |", true)
    t.match(md, "api_key = key, -- default: $EX_API_KEY", true)
  end)
end)

t.describe("gen: the CLI", function()
  if rex_api then
    t.pending("bin/distilled-lua runs under lua and luajit only (Rex has no io.popen)")
    return
  end
  local function run(cmd)
    local p = io.popen(cmd .. ' 2>&1; echo "exit:$?"')
    local out = p:read("*a")
    p:close()
    local code = tonumber(string.match(out, "exit:(%d+)%s*$"))
    return string.gsub(out, "exit:%d+%s*$", ""), code
  end
  local root = t.root
  local bin = "lua " .. root .. "/bin/distilled-lua"

  t.it("generate --ops writes a subset; an unknown op fails with suggestions", function()
    local dir = os.tmpname()
    os.remove(dir)
    local out, code = run(
      bin
        .. " generate --model "
        .. root
        .. "/models/neon.json --provider "
        .. root
        .. "/providers/neon.lua --out "
        .. dir
        .. "/neon --ops get_project,list_projects"
    )
    t.eq(code, 0, out)
    t.match(out, "2 operations", true)
    local f = io.open(dir .. "/neon/service.lua")
    t.truthy(f)
    local text = f:read("*a")
    f:close()
    t.match(text, "ops.get_project = {", true)
    t.match(text, "-- Operations: 2 of 178 (--ops).", true)
    out, code = run(
      bin
        .. " generate --model "
        .. root
        .. "/models/neon.json --provider "
        .. root
        .. "/providers/neon.lua --out "
        .. dir
        .. "/neon --ops get_projetc"
    )
    t.eq(code, 1)
    t.match(out, "unknown operation get_projetc; nearest: get_project", true)
    run("rm -rf " .. dir)
  end)

  t.it("bad arguments exit 2 with the usage", function()
    local out, code = run(bin .. " generate --model x")
    t.eq(code, 2)
    t.match(out, "generate needs --provider", true)
    out, code = run(bin .. " frobnicate")
    t.eq(code, 2)
    t.match(out, "unknown command frobnicate", true)
  end)

  t.it("vendor copies the runtime without gen/ and testing/", function()
    local dir = os.tmpname()
    os.remove(dir)
    local out, code = run(bin .. " vendor --out " .. dir)
    t.eq(code, 0, out)
    t.truthy(io.open(dir .. "/distilled/json.lua"))
    t.truthy(io.open(dir .. "/distilled/trace/init.lua"))
    t.falsy(io.open(dir .. "/distilled/gen/init.lua"))
    t.falsy(io.open(dir .. "/distilled/testing/init.lua"))
    run("rm -rf " .. dir)
  end)
end)
