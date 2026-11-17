-- Connect server streams (task 30): distilled.stream.connect envelopes,
-- distilled.protocol.connect's stream, and e2b's envd streaming RPCs
-- (start_process_stream, connect_process_stream, watch_dir_stream), ported from
-- Distilled's packages/e2b/src/connect.ts.
local t = require("spec.harness")
local errors = require("distilled.errors")
local json = require("distilled.json")
local envelopes = require("distilled.stream.connect")
local connect = require("distilled.protocol.connect")
local testing = require("distilled.testing")
local stub = require("spec.grpc_stream_stub")

local function load_client(name)
  package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path
  return require(name)
end

local Process = load_client("e2b.process")
local Filesystem = load_client("e2b.filesystem")
local Envd = load_client("e2b.envd")

local CT = { ["content-type"] = "application/connect+json" }

local function msg(value)
  return assert(envelopes.encode(value))
end

local function finish(value)
  return assert(envelopes.encode(value or json.object({}), 2))
end

local function process_client(replies, opts)
  local tr = stub.transport(replies)
  opts = opts or {}
  opts.sandbox_id = opts.sandbox_id or "sb-1"
  opts.access_token = opts.access_token or "envd-secret"
  opts.host = testing.host({ transport = tr })
  return Process.new(opts), tr
end

local function drain(stream)
  local items = {}
  for item, err in stream:iter() do
    if err ~= nil then
      return items, err
    end
    items[#items + 1] = item
  end
  return items, nil
end

t.describe("stream.connect envelopes", function()
  t.it("frames JSON and reads messages and the end-of-stream flag on any boundary", function()
    local body = msg({ a = 1 }) .. msg({ b = "x" }) .. finish({ metadata = { k = { "v" } } })
    t.eq(string.byte(body, 1), 0)
    t.eq(string.sub(body, 2, 5), "\0\0\0\7")
    for size = 1, 6 do
      local chunks = {}
      for i = 1, #body, size do
        chunks[#chunks + 1] = string.sub(body, i, i + size - 1)
      end
      local dec = envelopes.new(stub.reader(chunks))
      local a = assert(dec:next())
      t.eq(a.end_stream, false)
      t.eq(a.json.a, 1)
      t.eq(assert(dec:next()).json.b, "x")
      local e = assert(dec:next())
      t.eq(e.end_stream, true)
      t.eq(e.json.metadata.k[1], "v")
      t.eq((dec:next()), nil)
    end
  end)

  t.it("keeps invalid JSON as __invalidJson; a cut envelope is a ParseError", function()
    local dec = envelopes.new(stub.reader({ envelopes.frame("not json") }))
    t.eq(assert(dec:next()).json.__invalidJson, "not json")
    local whole = msg({ a = 1 })
    dec = envelopes.new(stub.reader({ string.sub(whole, 1, 7) }))
    local v, err = dec:next()
    t.eq(v, nil)
    t.truthy(errors.is(err))
    dec = envelopes.new(stub.reader({ string.sub(whole, 1, 5) }))
    v, err = dec:next()
    t.fails_with("ParseError", v, err)
    t.match(err.message, "truncated", true)
  end)
end)

t.describe("e2b envd streams", function()
  t.it("only the process and filesystem clients have the stream methods", function()
    local p = Process.new({ sandbox_id = "s" })
    t.eq(type(p.start_process_stream), "function")
    t.eq(type(p.connect_process_stream), "function")
    t.eq(p.watch_dir_stream, nil)
    local f = Filesystem.new({ sandbox_id = "s" })
    t.eq(type(f.watch_dir_stream), "function")
    t.eq(f.start_process_stream, nil)
    t.eq(Envd.new({ sandbox_id = "s" }).start_process_stream, nil)
  end)

  t.it("sends one envelope with envd's headers and streams decoded process events", function()
    local log = {}
    local c, tr = process_client({
      {
        status = 200,
        headers = CT,
        log = log,
        chunks = {
          msg({ event = { start = { pid = 42 } } }),
          msg({ event = { data = { stdout = "aGVsbG8K" } } }),
          msg({ event = { data = { stderr = "b29wcw==" } } }),
          msg({ event = { data = { pty = "" } } }),
          msg({ event = { keepalive = json.object({}) } }),
          msg({
            event = {
              ["end"] = { exitCode = 3, exited = true, status = "exit status 3", error = "boom" },
            },
          }),
          finish(),
        },
      },
    })
    local s = assert(c:start_process_stream({ process = { cmd = "sh", args = { "-c", "x" } } }))
    t.eq(s.status, 200)
    local req = tr.requests[1]
    t.eq(req.method, "POST")
    t.eq(req.url, "https://sandbox.e2b.app/process.Process/Start")
    t.eq(req.headers["content-type"], "application/connect+json")
    t.eq(req.headers["connect-protocol-version"], "1")
    t.eq(req.headers["e2b-sandbox-id"], "sb-1")
    t.eq(req.headers["e2b-sandbox-port"], "49983")
    t.eq(tostring(req.headers["x-access-token"]), "envd-secret")
    t.eq(req.body, envelopes.frame('{"process":{"args":["-c","x"],"cmd":"sh"}}'))
    local first = assert(s:next())
    t.same(first, { _tag = "Start", pid = 42 })
    t.same(log, { 1 }) -- the second envelope not yet read
    local items, err = drain(s)
    t.eq(err, nil)
    t.same(items[1], { _tag = "Stdout", data = "hello\n" })
    t.same(items[2], { _tag = "Stderr", data = "oops" })
    t.same(items[3], { _tag = "Pty", data = "" })
    t.same(items[4], { _tag = "KeepAlive" })
    t.same(
      items[5],
      { _tag = "End", exitCode = 3, exited = true, status = "exit status 3", error = "boom" }
    )
    t.eq(#items, 5)
    t.truthy(tr.readers[1].closed)
  end)

  t.it("connect_process_stream and watch_dir_stream address their methods", function()
    local c, tr = process_client({
      {
        status = 200,
        headers = CT,
        chunks = { msg({ event = { start = { pid = "7" } } }), finish() },
      },
    })
    local items = drain(assert(c:connect_process_stream({ process = { tag = "web" } })))
    t.same(items, { { _tag = "Start", pid = 7 } })
    t.eq(tr.requests[1].url, "https://sandbox.e2b.app/process.Process/Connect")
    local ftr = stub.transport({
      {
        status = 200,
        headers = CT,
        chunks = {
          msg({ start = json.object({}) }),
          msg({
            filesystem = {
              name = "a.txt",
              type = "EVENT_TYPE_CREATE",
              entry = { name = "a.txt", size = 3 },
            },
          }),
          msg({ filesystem = { name = 5 } }),
          msg({ keepalive = json.object({}) }),
          finish(),
        },
      },
    })
    local f = Filesystem.new({
      sandbox_id = "sb-2",
      domain = "e2b.dev",
      host = testing.host({ transport = ftr }),
    })
    local w = assert(f:watch_dir_stream({ path = "/home/user", recursive = true }))
    local ev = drain(w)
    t.eq(ftr.requests[1].url, "https://49983-sb-2.e2b.dev/filesystem.Filesystem/WatchDir")
    t.same(ev[1], { _tag = "Start" })
    t.eq(ev[2]._tag, "Filesystem")
    t.eq(ev[2].name, "a.txt")
    t.eq(ev[2].type, "EVENT_TYPE_CREATE")
    t.eq(ev[2].entry.size, 3)
    t.same(ev[3], { _tag = "Filesystem", name = "", type = "EVENT_TYPE_UNSPECIFIED" })
    t.same(ev[4], { _tag = "KeepAlive" })
  end)

  t.it("an end-of-stream error ends the stream with the mapped class", function()
    local cases = {
      { code = "not_found", tag = "NotFound" },
      { code = "invalid_argument", tag = "BadRequest" },
      { code = "failed_precondition", tag = "BadRequest" },
      { code = "unauthenticated", tag = "Unauthorized" },
      { code = "permission_denied", tag = "Forbidden" },
      { code = "already_exists", tag = "Conflict" },
      { code = "aborted", tag = "Conflict" },
      { code = "deadline_exceeded", tag = "UnknownE2BError" },
    }
    for _, case in ipairs(cases) do
      local c = process_client({
        {
          status = 200,
          headers = CT,
          chunks = {
            msg({ event = { start = { pid = 1 } } }),
            finish({ error = { code = case.code, message = "it failed" } }),
          },
        },
      })
      local items, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
      t.eq(#items, 1)
      t.fails_with(case.tag, nil, err)
      t.eq(err.message, "it failed")
      if case.tag == "UnknownE2BError" then
        t.eq(err.status, 200)
        t.eq(err.code, "deadline_exceeded")
      end
    end
    -- message falls back to the code
    local c = process_client({
      { status = 200, headers = CT, chunks = { finish({ error = { code = "not_found" } }) } },
    })
    local _, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.fails_with("NotFound", nil, err)
    t.eq(err.message, "not_found")
  end)

  t.it("maps a failure before the stream like connect.ts serverStream", function()
    local c, tr = process_client({
      {
        status = 502,
        headers = { ["content-type"] = "application/json" },
        chunks = { '{"sandboxId":"sb-1","message":"The sandbox was not found","code":502}' },
      },
      { status = 502, headers = {}, chunks = { "error code: 502" } },
      { status = 500, headers = {}, chunks = { "{}" } },
      { status = 404, headers = {}, chunks = { "404 page not found" } },
      {
        status = 400,
        headers = {},
        chunks = { '{"code":"invalid_argument","message":"bad cmd"}' },
      },
      { status = 409, headers = {}, chunks = { '{"code":"weird","message":"hm"}' } },
    })
    local input = { process = { cmd = "x" } }
    local s, err = c:start_process_stream(input)
    t.fails_with("SandboxNotRunning", s, err)
    t.eq(err.message, "The sandbox was not found")
    t.truthy(tr.readers[1].closed)
    s, err = c:start_process_stream(input)
    t.fails_with("SandboxNotRunning", s, err)
    t.eq(err.message, "sandbox sb-1 is not running")
    s, err = c:start_process_stream(input)
    t.fails_with("InternalServerError", s, err)
    t.eq(err.message, "HTTP 500")
    s, err = c:start_process_stream(input)
    t.fails_with("NotFound", s, err)
    t.eq(err.message, "envd process.Process/Start not found")
    s, err = c:start_process_stream(input)
    t.fails_with("BadRequest", s, err)
    t.eq(err.message, "bad cmd")
    s, err = c:start_process_stream(input)
    t.fails_with("UnknownE2BError", s, err)
    t.eq(err.status, 409)
    t.eq(err.code, "weird")
  end)

  t.it("a message that is not an event is an E2BParseError that ends the stream", function()
    local c, tr = process_client({
      {
        status = 200,
        headers = CT,
        chunks = {
          msg({ event = { start = { pid = 1 } } }),
          envelopes.frame("{oops"),
          msg({ event = {} }),
        },
      },
      { status = 200, headers = CT, chunks = { msg({ event = { mystery = json.object({}) } }) } },
      { status = 200, headers = CT, chunks = { msg({ event = { data = { stdout = "!!!" } } }) } },
    })
    local items, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.eq(#items, 1)
    t.fails_with("E2BParseError", nil, err)
    t.match(err.message, "missing event", true)
    t.eq(err.body.__invalidJson, "{oops")
    t.truthy(tr.readers[1].closed)
    _, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.match(err.message, "unknown process event", true)
    _, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.fails_with("E2BParseError", nil, err)
    t.match(err.message, "invalid base64", true)
  end)

  t.it("a drop mid-stream, a cut envelope and close()", function()
    local drop = errors.new("TransportError", { message = "connection reset" })
    local whole = msg({ event = { start = { pid = 2 } } })
    local c, tr = process_client({
      { status = 200, headers = CT, chunks = { msg({ event = { start = { pid = 1 } } }), drop } },
      { status = 200, headers = CT, chunks = { string.sub(whole, 1, 9) } },
      { status = 200, headers = CT, chunks = { whole, whole, whole } },
      { status = 200, headers = CT, chunks = { whole } },
    })
    local items, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.eq(#items, 1)
    t.fails_with("TransportError", nil, err)
    t.truthy(tr.readers[1].closed)
    _, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.truthy(errors.is(err))
    local s = assert(c:start_process_stream({ process = { cmd = "x" } }))
    t.truthy(s:next())
    s:close()
    s:close()
    t.eq(tr.readers[3].close_count, 1)
    -- a body that ends without the end-of-stream envelope ends the stream (connect.ts)
    items, err = drain(assert(c:start_process_stream({ process = { cmd = "x" } })))
    t.eq(#items, 1)
    t.eq(err, nil)
  end)

  t.it(
    "fails before sending without the sandbox, or with a transport that cannot stream",
    function()
      local p = Process.new({ host = testing.host({ transport = stub.transport({}) }) })
      local s, err = p:start_process_stream({ process = { cmd = "x" } })
      t.fails_with("ConfigError", s, err)
      p = Process.new({
        sandbox_id = "s",
        host = testing.host({ transport = testing.transport({ responses = {} }) }),
      })
      s, err = p:start_process_stream({ process = { cmd = "x" } })
      t.fails_with("ConfigError", s, err)
      t.match(err.message, "cannot stream", true)
    end
  )

  t.it("connect.stream without hooks returns raw messages and the unknown class", function()
    local proto =
      connect.new({ base_url = "https://h.test", unknown_tag = "UnknownX", parse_tag = "XParse" })
    local tr = stub.transport({
      {
        status = 200,
        headers = CT,
        chunks = { msg({ n = 1 }), finish({ error = { code = "internal", message = "m" } }) },
      },
    })
    local ctx = { service = { name = "x", ops = {} }, host = testing.host({ transport = tr }) }
    local op = { name = "Watch", method = "POST", uri = "/x.X/Watch", code = 200, errors = {} }
    local parts = assert(connect.stream(proto, ctx, op, { a = 1 }))
    t.eq(parts.next().n, 1)
    local v, err = parts.next()
    t.fails_with("UnknownX", v, err)
    t.eq(err.code, "internal")
    t.eq(err.status, 200)
  end)
end)
