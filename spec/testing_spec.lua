local t = require("spec.harness")
local testing = require("distilled.testing")
local fixtures = require("distilled.testing.fixtures")
local errors = require("distilled.errors")
local json = require("distilled.json")

t.describe("testing.transport", function()
  t.it("returns responses in order and records every request", function()
    local tr = testing.transport({
      responses = {
        { status = 500 },
        { status = 200, body = { id = 1 }, headers = { ["X-Req"] = "r" } },
      },
    })
    local r1 = tr({ method = "GET", url = "https://x/1", headers = { a = "1" } })
    t.eq(r1.status, 500)
    t.eq(r1.body, "")
    local r2 = tr({ method = "POST", url = "https://x/2", body = "{}" })
    t.eq(r2.status, 200)
    t.eq(r2.body, '{"id":1}')
    t.eq(r2.headers["x-req"], "r")
    t.eq(r2.headers["content-type"], "application/json")
    t.eq(#tr.requests, 2)
    t.eq(tr.requests[1].url, "https://x/1")
    t.eq(tr.requests[1].headers.a, "1")
    t.eq(tr.requests[2].body, "{}")
    t.eq(tr:remaining(), 0)
  end)

  t.it("records a copy of the headers", function()
    local tr = testing.transport({ responses = { {} } })
    local headers = { a = "1" }
    tr({ method = "GET", url = "u", headers = headers })
    headers.a = "2"
    t.eq(tr.requests[1].headers.a, "1")
  end)

  t.it("an error entry is returned as nil, err", function()
    local failure = errors.new("TransportError", { message = "connection refused" })
    local tr = testing.transport({ responses = { failure } })
    local res, err = tr({ method = "GET", url = "u" })
    t.eq(res, nil)
    t.eq(err, failure)
  end)

  t.it("a function entry receives the request", function()
    local tr = testing.transport({
      responses = {
        function(req)
          return { status = 201, body = req.url }
        end,
        function()
          return nil, errors.new("TransportError", { message = "timeout" })
        end,
      },
    })
    t.eq(tr({ method = "GET", url = "echo" }).body, "echo")
    t.fails_with("TransportError", tr({ method = "GET", url = "x" }))
  end)

  t.it("fails loudly when it runs out", function()
    local tr = testing.transport({ responses = { {} } })
    tr({ method = "GET", url = "a" })
    t.raises(function()
      tr({ method = "DELETE", url = "https://x/b" })
    end, "no scripted response for request #2 %(DELETE https://x/b%)")
    t.eq(tr.exhausted, true)
    t.eq(#tr.requests, 2)
  end)

  t.it("accepts a bare list of responses", function()
    local tr = testing.transport({ { status = 204 } })
    t.eq(tr({ method = "GET", url = "u" }).status, 204)
  end)
end)

t.describe("testing.host", function()
  t.it("sleep advances the fake clock and is recorded", function()
    local host = testing.host({ now = 10 })
    t.eq(host.now(), 10)
    host.sleep(0.25)
    host.sleep(1)
    t.eq(host.now(), 11.25)
    t.same(host.sleeps, { 0.25, 1 })
    t.eq(host.epoch(), 1700000000 + 11.25)
  end)

  t.it("random is seeded and deterministic, in [0, 1)", function()
    local a, b = testing.host({ seed = 7 }), testing.host({ seed = 7 })
    local c = testing.host({ seed = 8 })
    local same, differs = true, false
    for _ = 1, 100 do
      local x, y, z = a.random(), b.random(), c.random()
      if x ~= y then
        same = false
      end
      if x ~= z then
        differs = true
      end
      t.truthy(x >= 0 and x < 1)
    end
    t.truthy(same)
    t.truthy(differs)
  end)

  t.it("random gives the same first values on every runtime", function()
    local r = testing.random(1)
    -- Park-Miller from seed 1 (state 2): 33614, 564950498, ...
    t.eq(r(), (33614 - 1) / 2147483646)
    t.eq(r(), (564950498 - 1) / 2147483646)
    local d = testing.random(3)
    for _ = 1, 50 do
      local v = d(1, 6)
      t.truthy(v >= 1 and v <= 6 and v == math.floor(v))
    end
  end)

  t.it("getenv reads the given table", function()
    local host = testing.host({ env = { NEON_API_KEY = "k" } })
    t.eq(host.getenv("NEON_API_KEY"), "k")
    t.eq(host.getenv("HOME"), nil)
  end)

  t.it("carries the scripted transport", function()
    local host = testing.host({ responses = { { status = 200 } } })
    t.eq(host.transport({ method = "GET", url = "u" }).status, 200)
    t.eq(host.requests[1].url, "u")
  end)

  t.it("sleep with a bad argument raises (misuse)", function()
    t.raises(function()
      testing.host().sleep("1")
    end, "number of seconds")
  end)
end)

t.describe("testing.fixtures", function()
  t.it("the service has the contract's shape and every ref resolves", function()
    local S = require("distilled.schema")
    local s = fixtures.service()
    t.eq(s.name, "neon")
    local count = 0
    for name, o in pairs(s.ops) do
      count = count + 1
      t.truthy(o.name and o.method and o.uri, name)
      for _, e in ipairs(o.errors) do
        t.truthy(errors.is_class(s.errors[e]), name .. " error " .. e)
      end
      local node = S.resolve(o.input, s.shapes)
      t.eq(node.t, "struct")
      if o.output then
        t.truthy(S.resolve(o.output, s.shapes), name .. " output")
      end
    end
    t.truthy(count >= 5)
    for name, shape in pairs(s.shapes) do
      for _, m in ipairs(shape.members or {}) do
        local n = m.schema
        while n.t == "list" or n.t == "map" do
          n = n.item or n.value
        end
        t.truthy(S.resolve(n, s.shapes), name .. "." .. m.name)
      end
    end
  end)

  t.it("list_projects is paginated like Neon's", function()
    local p = fixtures.service().ops.list_projects.pagination
    t.eq(p.mode, "cursor")
    t.eq(p.output_token, "pagination.cursor")
    t.eq(p.items, "projects")
  end)

  t.it("the regex error matcher picks ProjectLocked over the bare status", function()
    local s = fixtures.service()
    local classes = {}
    for i, e in ipairs(s.ops.create_project.errors) do
      classes[i] = s.errors[e]
    end
    local err =
      errors.match(classes, { status = 423, message = "project p1 is locked by an operation" })
    t.eq(err.tag, "ProjectLocked")
    t.eq(errors.match(classes, { status = 423, message = "branch is locked" }).tag, "Locked")
  end)

  t.it("bodies encode to JSON a transport can return", function()
    local page = fixtures.bodies.page({ "a" }, "next")
    t.eq(json.decode(json.encode(page)).pagination.cursor, "next")
    local last = fixtures.bodies.page({}, nil)
    t.eq(json.encode(last), '{"projects":[]}')
    t.eq(fixtures.bodies.api_key().key, "napi_FIXTURE-SECRET")
  end)
end)
