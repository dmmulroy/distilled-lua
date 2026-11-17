-- distilled.host.popen: the one-line host for stock Lua and LuaJIT (popen_curl transport,
-- a shell sleep, os.time). Rex has no io.popen: there the module refuses with a clear
-- error and points at distilled.host.rex.
local t = require("spec.harness")

local REX = rawget(_G, "rex") ~= nil

t.describe("distilled.host.popen", function()
  if REX then
    t.it("refuses in Rex and names distilled.host.rex", function()
      t.raises(function()
        require("distilled.host.popen")()
      end, "distilled.host.rex")
    end)
    return
  end

  local popen_host = require("distilled.host.popen")

  t.it("has the host fields, and no exec", function()
    local h = popen_host()
    -- a callable table: the plain transport plus its stream and duplex entry points (task 31)
    t.truthy(require("distilled.host").callable(h.transport), "the transport is callable")
    t.eq(type(h.transport.stream), "function")
    t.eq(type(h.transport.duplex), "function")
    t.eq(type(h.sleep), "function")
    t.eq(h.now, os.time)
    t.eq(h.epoch, os.time)
    t.eq(h.exec, nil)
    t.eq(h.name, "popen")
  end)

  t.it("sleep waits in a child process (wall time, not CPU time)", function()
    local h = popen_host()
    local before_cpu = os.clock()
    local before = os.time()
    h.sleep(1.2)
    local elapsed = os.time() - before
    t.truthy(elapsed >= 1, "wall seconds elapsed: " .. elapsed)
    t.truthy(os.clock() - before_cpu < 0.5, "a shell sleep does not spin the CPU")
  end)

  t.it("sleep ignores zero, negative, NaN and non-numbers", function()
    local h = popen_host()
    local before = os.clock()
    h.sleep(0)
    h.sleep(-1)
    h.sleep(0 / 0)
    h.sleep("1")
    t.truthy(os.clock() - before < 0.2)
  end)

  t.it("passes transport options through", function()
    local h = popen_host({ curl = "/nonexistent/curl" })
    local res, err = h.transport({ method = "GET", url = "http://127.0.0.1:9/", headers = {} })
    t.eq(res, nil)
    t.eq(err.tag, "TransportError")
  end)

  t.it("works as a client's host", function()
    local serve = require("verify.lib.serve")
    if not serve.url() then
      t.pending("DL_SERVE_URL is not set (run verify/dl test --http)")
      return
    end
    local h = popen_host()
    local s = serve.client(h.transport)
    s.script("/hostpopen/projects/p1", {
      { status = 503, headers = { ["retry-after"] = "1" }, json = { message = "busy" } },
      { status = 200, json = { project = { id = "p1", name = "demo" } } },
    })
    local Fixture = serve.fixture_class()
    local client = Fixture.new({ api_key = "k", base_url = serve.url() .. "/hostpopen", host = h })
    local before = os.time()
    local value, err = client:get_project({ project_id = "p1" })
    t.eq(err, nil)
    t.eq(value.project.id, "p1")
    t.truthy(os.time() - before >= 1, "slept for the Retry-After second")
  end)
end)
