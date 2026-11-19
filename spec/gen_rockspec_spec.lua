local t = require("spec.harness")
local rockspec = require("distilled.gen.rockspec")

-- Loads a rockspec's text the way LuaRocks does: as assignments to globals.
local function load_rockspec(text)
  local env = {}
  local chunk
  if setfenv then
    chunk = assert(loadstring(text))
    setfenv(chunk, env)
  else
    chunk = assert(load(text, "rockspec", "t", env))
  end
  chunk()
  return env
end

t.describe("gen.rockspec: names", function()
  t.it("a client's rock is distilled-<provider>, underscores as dashes", function()
    t.eq(rockspec.client_rock_name("twitch"), "distilled-twitch")
    t.eq(rockspec.client_rock_name("boat_dev"), "distilled-boat-dev")
  end)
  t.it("a file's module drops init.lua and takes the prefix", function()
    t.eq(
      rockspec.module_of_file("clients/twitch/init.lua", "clients/", "distilled.clients."),
      "distilled.clients.twitch"
    )
    t.eq(
      rockspec.module_of_file("clients/twitch/chat/service.lua", "clients/", "distilled.clients."),
      "distilled.clients.twitch.chat.service"
    )
    t.eq(rockspec.module_of_file("lua/distilled/init.lua", "lua/"), "distilled")
    t.eq(rockspec.module_of_file("lua/distilled/crypto/sha1.lua", "lua/"), "distilled.crypto.sha1")
  end)
end)

t.describe("gen.rockspec: the runtime rock", function()
  local rock = assert(rockspec.runtime_rockspec({
    version = "0.1.0",
    files = { "lua/distilled/init.lua", "lua/distilled/json.lua", "lua/distilled/crypto/sha1.lua" },
  }))
  local spec = load_rockspec(rock.text)
  t.it("is a LuaRocks 3.0 rockspec with revision 1", function()
    t.eq(spec.rockspec_format, "3.0")
    t.eq(spec.package, "distilled")
    t.eq(spec.version, "0.1.0-1")
    t.eq(rock.rockspec_file, "distilled-0.1.0-1.rockspec")
  end)
  t.it("builds from its own release archive, not the repository", function()
    t.eq(
      spec.source.url,
      "https://github.com/dmmulroy/distilled-lua/releases/download/v0.1.0/distilled-0.1.0.tar.gz"
    )
    t.eq(spec.source.dir, "distilled-0.1.0")
    t.eq(rock.archive_dir, "distilled-0.1.0")
  end)
  t.it("maps every module to its file, and needs nothing but Lua 5.1", function()
    t.eq(spec.build.type, "builtin")
    t.same(spec.build.modules, {
      distilled = "lua/distilled/init.lua",
      ["distilled.json"] = "lua/distilled/json.lua",
      ["distilled.crypto.sha1"] = "lua/distilled/crypto/sha1.lua",
    })
    t.same(spec.dependencies, { "lua >= 5.1" })
    t.eq(spec.description.license, "Apache-2.0")
  end)
  t.it("puts the license in the archive", function()
    t.same(
      rock.files,
      {
        "lua/distilled/init.lua",
        "lua/distilled/json.lua",
        "lua/distilled/crypto/sha1.lua",
        "LICENSE",
        "NOTICE",
      }
    )
  end)
end)

t.describe("gen.rockspec: a client rock", function()
  local rock = assert(rockspec.client_rockspec({
    version = "0.2.3",
    provider = "twitch",
    title = "Twitch",
    files = {
      "clients/twitch/init.lua",
      "clients/twitch/chat/init.lua",
      "clients/twitch/chat/service.lua",
    },
  }))
  local spec = load_rockspec(rock.text)
  t.it("installs under distilled.clients.<provider>", function()
    t.eq(spec.package, "distilled-twitch")
    t.same(spec.build.modules, {
      ["distilled.clients.twitch"] = "clients/twitch/init.lua",
      ["distilled.clients.twitch.chat"] = "clients/twitch/chat/init.lua",
      ["distilled.clients.twitch.chat.service"] = "clients/twitch/chat/service.lua",
    })
  end)
  t.it("depends on the runtime of the same version", function()
    t.same(spec.dependencies, { "lua >= 5.1", "distilled == 0.2.3" })
    t.eq(
      spec.source.url,
      "https://github.com/dmmulroy/distilled-lua/releases/download/v0.2.3/distilled-twitch-0.2.3.tar.gz"
    )
    t.match(spec.description.detailed, 'require("distilled.clients.twitch")', true)
  end)
end)

t.describe("gen.rockspec: refuses bad input", function()
  t.it("a version that is not MAJOR.MINOR.PATCH", function()
    local rock, err = rockspec.runtime_rockspec({ version = "1.0", files = {} })
    t.eq(rock, nil)
    t.match(err, "MAJOR.MINOR.PATCH", true)
  end)
  t.it("a provider that is not a Lua name", function()
    local rock, err =
      rockspec.client_rockspec({ version = "1.0.0", provider = "Bad-Name", files = {} })
    t.eq(rock, nil)
    t.match(err, "lowercase Lua name", true)
  end)
  t.it("two files that would be the same module", function()
    local rock, err = rockspec.client_rockspec({
      version = "1.0.0",
      provider = "x",
      files = { "clients/x/a.lua", "clients/x/a/init.lua" },
    })
    t.eq(rock, nil)
    t.match(err, "two files give module distilled.clients.x.a", true)
  end)
end)
