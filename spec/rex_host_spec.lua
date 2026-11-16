-- distilled.host.rex: built against a fake `rex` global everywhere, and against the real
-- one under `rex do` (where os.clock is wall time and rex.exec runs commands).
local t = require("spec.harness")
local json = require("distilled.json")
local serve = require("verify.lib.serve")

local REAL_REX = rawget(_G, "rex")
local make_host = require("distilled.host.rex")

-- runs fn with the global `rex` replaced by fake (nil allowed), restoring it on every path
local function with_rex(fake, fn)
  local saved = rawget(_G, "rex")
  rawset(_G, "rex", fake)
  local ok, raised = t.pcall(fn)
  rawset(_G, "rex", saved)
  if not ok then
    error(raised, 0)
  end
end

local function fake_rex(with_sleep)
  local log = { exec = {}, sleep = {} }
  local rex = {
    exec = function(argv, opts)
      log.exec[#log.exec + 1] = { argv = argv, opts = opts }
      if argv[1] == "sleep" then
        return { code = 0, ok = true, stdout = "", stderr = "" }
      end
      return {
        code = 0,
        ok = true,
        stderr = "",
        stdout = "HTTP/1.1 200 OK\r\n\r\nhi\n--distilled-curl-write-out-- 200 2",
      }
    end,
  }
  if with_sleep then
    rex.sleep = function(s)
      log.sleep[#log.sleep + 1] = s
    end
  end
  return rex, log
end

t.describe("host.rex", function()
  t.it("fails with a clear message when the global rex is absent", function()
    with_rex(nil, function()
      t.raises(function()
        make_host()
      end, "the global `rex`")
    end)
    with_rex({}, function()
      t.raises(function()
        make_host()
      end, "rex.exec")
    end)
  end)

  t.it("uses rex.sleep when it exists (rex do scripts)", function()
    local rex, log = fake_rex(true)
    with_rex(rex, function()
      local host = make_host()
      host.sleep(0.25)
      host.sleep(0) -- nothing to wait for
      t.same(log.sleep, { 0.25 })
      t.eq(#log.exec, 0)
    end)
  end)

  t.it("falls back to rex.exec{ sleep } (the configuration file has no rex.sleep)", function()
    local rex, log = fake_rex(false)
    with_rex(rex, function()
      local host = make_host()
      host.sleep(0.05)
      t.eq(#log.exec, 1)
      t.same(log.exec[1].argv, { "sleep", "0.050" })
      t.truthy(log.exec[1].opts.timeout > 0.05)
    end)
  end)

  t.it("has exec, now, epoch, and an exec_curl transport over rex.exec", function()
    local rex, log = fake_rex(true)
    with_rex(rex, function()
      local host = make_host()
      t.eq(host.now, os.clock)
      t.eq(type(host.epoch()), "number")
      local r = host.exec({ "true" })
      t.eq(r.code, 0)
      local res = host.transport({
        method = "GET",
        url = "http://x.test/",
        headers = { authorization = "Bearer sk-CANARY-host" },
        timeout = 4,
      })
      t.eq(res.status, 200)
      t.eq(res.body, "hi")
      local call = log.exec[2]
      t.same(call.argv, { "curl", "-q", "--config", "-" })
      t.eq(call.opts.timeout, 6)
      t.match(call.opts.stdin, "sk-CANARY-host", true)
    end)
  end)

  t.it("accepts a callable-table rex.exec (Rex's real one has .start)", function()
    local rex, log = fake_rex(true)
    local fn = rex.exec
    rex.exec = setmetatable({ start = function() end }, {
      __call = function(_, argv, opts)
        return fn(argv, opts)
      end,
    })
    with_rex(rex, function()
      local host = make_host()
      t.eq(host.transport({ method = "GET", url = "http://x/" }).status, 200)
      t.eq(#log.exec, 1)
    end)
  end)
end)

if REAL_REX then
  t.describe("host.rex in Rex", function()
    t.it("now is wall time: sleep(0.2) advances it by about 0.2 s", function()
      local host = make_host()
      local a = host.now()
      host.sleep(0.2)
      local d = host.now() - a
      t.truthy(d >= 0.18 and d < 1.5, "elapsed " .. tostring(d))
    end)

    t.it("the config-file sleep (rex.exec sleep) really waits", function()
      local fake = { exec = REAL_REX.exec } -- no sleep, as in the configuration file
      with_rex(fake, function()
        local host = make_host()
        local a = os.clock()
        host.sleep(0.2)
        local d = os.clock() - a
        t.truthy(d >= 0.18 and d < 2, "elapsed " .. tostring(d))
      end)
    end)

    local base = serve.url()
    if base then
      t.it("sends a request through rex.exec to dl serve", function()
        local host = make_host()
        local r, err = host.transport({
          method = "POST",
          url = base .. "/_dl/echo",
          headers = {
            authorization = "Bearer sk-CANARY-rex",
            ["content-type"] = "application/json",
          },
          body = '{"a":1}',
          timeout = 5,
        })
        t.truthy(r, tostring(err))
        local e = json.decode(r.body)
        t.eq(e.headers.authorization, "Bearer sk-CANARY-rex")
        t.eq(e.body, '{"a":1}')
      end)
    else
      t.pending("host.rex over HTTP: skipped, DL_SERVE_URL is not set (verify/dl test --http)")
    end
  end)
end
