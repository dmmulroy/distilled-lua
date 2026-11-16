-- curl transports: curl_common (config, parsing, failures) offline, then popen_curl and
-- exec_curl against the `dl serve` fixture server when DL_SERVE_URL is set
-- (verify/dl test --http sets it). Under lua/luajit both popen_curl and exec_curl (over an
-- io.popen exec shim) run; under Rex exec_curl runs over rex.exec.
local t = require("spec.harness")
local common = require("distilled.transport.curl_common")
local exec_curl = require("distilled.transport.exec_curl")
local popen_curl = require("distilled.transport.popen_curl")
local json = require("distilled.json")
local serve = require("verify.lib.serve")

local REX = rawget(_G, "rex")
local SECRET = "sk-CANARY-transport-0123456789"

-- asserts a transport-style result succeeded and returns the value; on failure shows err
local function ok(v, e)
  if not v then
    t.fail("expected a value, got nil, " .. tostring(e))
  end
  return v
end

-- a fake exec that records its calls and answers with a canned result
local function fake_exec(result, err)
  local calls = {}
  local exec = function(argv, opts)
    calls[#calls + 1] = { argv = argv, opts = opts }
    if type(result) == "function" then
      return result(argv, opts)
    end
    return result, err
  end
  return exec, calls
end

local function curl_output(head, body, status)
  return head .. body .. "\n" .. common.TRAILER .. " " .. (status or 200) .. " " .. #body
end

local OK_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"

t.describe("curl_common.check", function()
  t.it("accepts a normal request", function()
    t.truthy(common.check({ method = "GET", url = "https://x.test/a?b=1", headers = { a = "b" } }))
  end)
  t.it("refuses a header value with a newline, CR or NUL (InvalidInput)", function()
    for _, v in ipairs({ "a\nb", "a\rb", "a\0b", "x\r\nInjected: 1" }) do
      local e = t.fails_with(
        "InvalidInput",
        common.check({ method = "GET", url = "http://x.test/", headers = { ["x-a"] = v } })
      )
      t.no_match(e.message, v, true)
    end
  end)
  t.it("refuses a bad header name, method, URL, body type", function()
    t.fails_with(
      "InvalidInput",
      common.check({ method = "GET", url = "http://x/", headers = { ["a b"] = "1" } })
    )
    t.fails_with(
      "InvalidInput",
      common.check({ method = "GET", url = "http://x/", headers = { ["a:b"] = "1" } })
    )
    t.fails_with("InvalidInput", common.check({ method = "G T", url = "http://x/" }))
    t.fails_with("InvalidInput", common.check({ method = "GET", url = "ftp://x/" }))
    t.fails_with("InvalidInput", common.check({ method = "GET", url = "file:///etc/passwd" }))
    t.fails_with("InvalidInput", common.check({ method = "GET", url = "http://x/a b" }))
    t.fails_with("InvalidInput", common.check({ method = "GET", url = "http://x/\n" }))
    t.fails_with("InvalidInput", common.check({ method = "POST", url = "http://x/", body = {} }))
    t.fails_with("InvalidInput", common.check({ method = "GET", url = "http://x/", timeout = "5" }))
    t.fails_with("InvalidInput", common.check("GET http://x/"))
  end)
end)

t.describe("curl_common.config", function()
  t.it("escapes quotes and backslashes in values", function()
    local text =
      common.config({ method = "GET", url = 'http://x.test/"q"', headers = { ["x-a"] = 'a"b\\c' } })
    t.match(text, 'url = "http://x.test/\\"q\\""', true)
    t.match(text, 'header = "x-a: a\\"b\\\\c"', true)
  end)
  t.it("sends an empty header as `name;` (curl's `name:` would remove it)", function()
    local text =
      common.config({ method = "GET", url = "http://x/", headers = { ["x-empty"] = "" } })
    t.match(text, 'header = "x-empty;"', true)
  end)
  t.it("never follows redirects unless asked, and disables .curlrc globbing and Expect", function()
    local text = common.config({ method = "GET", url = "http://x/" })
    t.no_match(text, "location")
    t.match(text, "globoff", true)
    t.match(text, 'header = "Expect:"', true)
    t.match(
      common.config({ method = "GET", url = "http://x/" }, { follow_redirects = true }),
      "location",
      true
    )
  end)
  t.it("maps timeout to max-time and a body to data-binary @file", function()
    local text = common.config(
      { method = "POST", url = "http://x/", body = "{}", timeout = 2.5 },
      { body_path = "/dev/fd/3" }
    )
    t.match(text, "max-time = 2.500", true)
    t.match(text, 'data-binary = "@/dev/fd/3"', true)
    t.match(text, 'header = "Content-Type:"', true) -- no form content type sneaks in
    local typed = common.config({
      method = "POST",
      url = "http://x/",
      body = "{}",
      headers = { ["content-type"] = "application/json" },
    }, { body_path = "/b" })
    t.no_match(typed, 'header = "Content-Type:"', true)
  end)
  t.it("uses `head` for HEAD (request = HEAD would hang)", function()
    local text = common.config({ method = "HEAD", url = "http://x/" })
    t.match(text, "\nhead\n", true)
    t.no_match(text, "request =", true)
  end)
end)

t.describe("curl_common.parse", function()
  t.it("takes status, lowercased headers (repeats joined) and the exact body", function()
    local head =
      "HTTP/1.1 201 Created\r\nX-Multi: 1\r\nx-multi: 2\r\nContent-Type: application/json\r\n\r\n"
    local r = ok(common.parse(curl_output(head, '{"a":1}', 201), { method = "POST" }))
    t.eq(r.status, 201)
    t.eq(r.headers["x-multi"], "1, 2")
    t.eq(r.headers["content-type"], "application/json")
    t.eq(r.body, '{"a":1}')
  end)
  t.it("skips 100 Continue and earlier (redirect) blocks", function()
    local head =
      "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 302 Found\r\nLocation: /b\r\n\r\nHTTP/2 404\r\nx-last: yes\r\n\r\n"
    local out = head .. "nope" .. "\n" .. common.TRAILER .. " 404 4"
    local r = common.parse(out, { method = "GET" })
    t.eq(r.status, 404)
    t.eq(r.headers["x-last"], "yes")
    t.eq(r.headers.location, nil)
    t.eq(r.body, "nope")
  end)
  t.it("keeps a body that looks like headers or like the trailer", function()
    local body = "\r\n\r\nHTTP/1.1 500 Bad\r\n\r\n\n" .. common.TRAILER .. " 500 3\n\0\255"
    local r = common.parse(curl_output(OK_HEAD, body), { method = "GET" })
    t.eq(r.status, 200)
    t.eq(r.body, body)
  end)
  t.it("returns an empty body as the empty string", function()
    local r = common.parse(
      "HTTP/1.1 204 No Content\r\n\r\n\n" .. common.TRAILER .. " 204 0",
      { method = "DELETE" }
    )
    t.eq(r.status, 204)
    t.eq(r.body, "")
  end)
  t.it("fails with TransportError on output without a trailer or status line", function()
    t.fails_with("TransportError", common.parse("garbage", { method = "GET" }))
    t.fails_with(
      "TransportError",
      common.parse("\n" .. common.TRAILER .. " 200 0", { method = "GET" })
    )
    t.fails_with(
      "TransportError",
      common.parse("x\n" .. common.TRAILER .. " 200 99", { method = "GET" })
    )
  end)
  t.it("handles a 5 MB body (no quadratic work)", function()
    local body = string.rep("0123456789", 500000)
    local r = common.parse(curl_output(OK_HEAD, body), { method = "GET" })
    t.eq(#r.body, #body)
    t.truthy(r.body == body)
  end)
end)

t.describe("curl_common.failure", function()
  t.it("marks exit 28 and a killed process as timeouts", function()
    local e =
      common.failure({ code = 28, stderr = "curl: (28) Operation timed out after 500 ms\n" })
    t.eq(e.tag, "TransportError")
    t.eq(e.timeout, true)
    t.eq(e.categories.TimeoutError, true)
    t.eq(e.categories.NetworkError, true)
    t.match(e.message, "timed out")
    local k = common.failure({ code = -1, timed_out = true, stderr = "" })
    t.eq(k.timeout, true)
    t.match(k.message, "stopped")
  end)
  t.it("names a missing curl", function()
    t.match(
      common.failure({ code = 127, stderr = "sh: curl: command not found" }).message,
      "^curl not found"
    )
    t.match(common.failure({ not_found = true, message = "x" }).message, "^curl not found")
  end)
  t.it("scrubs header values, the query, userinfo and the body from curl's message", function()
    local req = {
      method = "POST",
      url = "https://user:pw-secret@x.test/a?api_key=" .. SECRET,
      headers = { authorization = "Bearer " .. SECRET },
      body = '{"token":"' .. SECRET .. '"}',
    }
    local stderr = "curl: (3) bad thing in https://user:pw-secret@x.test/a?api_key="
      .. SECRET
      .. " Bearer "
      .. SECRET
    local e = common.failure({ code = 3, stderr = stderr, request = req })
    t.no_match(e.message, SECRET, true)
    t.no_match(e.message, "pw-secret", true)
    t.match(e.message, "<redacted>", true)
    t.eq(e.curl_code, 3)
    t.falsy(e.timeout)
  end)
end)

t.describe("exec_curl (fake exec)", function()
  local req = {
    method = "GET",
    url = "http://x.test/a",
    headers = { authorization = "Bearer " .. SECRET },
    timeout = 3,
  }
  t.it("puts the request on stdin, never in argv, and adds a timeout margin", function()
    local exec, calls =
      fake_exec({ code = 0, ok = true, stdout = curl_output(OK_HEAD, "hi"), stderr = "" })
    local r = ok(exec_curl(exec)(req))
    t.eq(r.body, "hi")
    t.same(calls[1].argv, { "curl", "-q", "--config", "-" })
    t.match(calls[1].opts.stdin, 'header = "authorization: Bearer ' .. SECRET, true)
    t.eq(calls[1].opts.timeout, 5)
    t.match(calls[1].opts.stdin, "max-time = 3.000", true)
    for _, a in ipairs(calls[1].argv) do
      t.no_match(a, SECRET, true)
    end
  end)
  t.it(
    "sends a body after the config, with the config length as the only number in argv",
    function()
      local exec, calls =
        fake_exec({ code = 0, ok = true, stdout = curl_output(OK_HEAD, ""), stderr = "" })
      local body = '{"secret":"' .. SECRET .. '"}\0'
      t.truthy(exec_curl(exec, { margin_s = 1 })({
        method = "POST",
        url = "http://x/",
        body = body,
        timeout = 1,
      }))
      local c = calls[1]
      t.eq(c.argv[1], "sh")
      local n = tonumber(c.argv[5])
      t.eq(string.sub(c.opts.stdin, n + 1), body)
      t.match(string.sub(c.opts.stdin, 1, n), 'data-binary = "@/dev/fd/3"', true)
      t.eq(c.argv[6], "curl")
      t.eq(c.opts.timeout, 2)
      for _, a in ipairs(c.argv) do
        t.no_match(a, SECRET, true)
      end
    end
  )
  t.it("no timeout: no exec timeout", function()
    local exec, calls =
      fake_exec({ code = 0, ok = true, stdout = curl_output(OK_HEAD, ""), stderr = "" })
    exec_curl(exec)({ method = "GET", url = "http://x/" })
    t.eq(calls[1].opts.timeout, nil)
  end)
  t.it("exec returning nil is TransportError (curl not found)", function()
    local exec = fake_exec(nil, "curl: executable file not found in PATH")
    local e = t.fails_with("TransportError", exec_curl(exec)(req))
    t.match(e.message, "curl not found")
  end)
  t.it("a timed-out exec is a timeout TransportError", function()
    local exec = fake_exec({ code = -1, ok = false, stdout = "", stderr = "", timed_out = true })
    local e = t.fails_with("TransportError", exec_curl(exec)(req))
    t.eq(e.timeout, true)
  end)
  t.it("a curl failure is TransportError with curl's message, scrubbed", function()
    local exec = fake_exec({
      code = 7,
      ok = false,
      stdout = "",
      stderr = "curl: (7) Failed to connect to x.test port 80: Connection refused Bearer "
        .. SECRET
        .. "\n",
    })
    local e = t.fails_with("TransportError", exec_curl(exec)(req))
    t.eq(e.curl_code, 7)
    t.match(e.message, "^curl: %(7%) Failed to connect")
    t.no_match(e.message, SECRET, true)
    t.no_match(tostring(e), SECRET, true)
  end)
  t.it("an invalid request never reaches exec", function()
    local exec, calls = fake_exec({})
    t.fails_with(
      "InvalidInput",
      exec_curl(exec)({ method = "GET", url = "http://x/", headers = { a = "1\n2" } })
    )
    t.eq(#calls, 0)
  end)
  t.it("refuses a non-function exec (misuse)", function()
    t.raises(function()
      exec_curl("rex.exec")
    end, "exec_curl: expected exec")
  end)
end)

if REX then
  t.describe("popen_curl in Rex", function()
    t.it("returns TransportError pointing to exec_curl (io.popen raises in Rex)", function()
      local e = t.fails_with(
        "TransportError",
        popen_curl()({ method = "GET", url = "http://127.0.0.1:1/" })
      )
      t.match(e.message, "exec_curl", true)
    end)
  end)
end

---------------------------------------------------------------------------------------
-- over real HTTP, against dl serve
---------------------------------------------------------------------------------------

local BASE = serve.url()

local function transports()
  if REX then
    return { { name = "exec_curl(rex.exec)", key = "rex", tr = exec_curl(REX.exec) } }
  end
  return {
    { name = "popen_curl", key = "popen", tr = popen_curl() },
    { name = "exec_curl(popen shim)", key = "shim", tr = exec_curl(serve.popen_exec) },
  }
end

local function echo(tr, req)
  local r = ok(tr(req))
  t.eq(r.status, 200, "echo status")
  return json.decode(r.body), r
end

if not BASE then
  t.describe("transport over HTTP", function()
    t.pending("skipped: DL_SERVE_URL is not set (run verify/dl test --http)")
  end)
else
  for _, entry in ipairs(transports()) do
    local tr, key = entry.tr, entry.key
    local s = serve.client(tr)
    local function url(path)
      return BASE .. path
    end

    t.describe("transport over HTTP: " .. entry.name, function()
      t.it("sends every method; HEAD has an empty body", function()
        for _, m in ipairs({ "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS" }) do
          local e = echo(tr, { method = m, url = url("/_dl/echo/" .. key) })
          t.eq(e.method, m)
        end
        local r = ok(tr({ method = "HEAD", url = url("/_dl/bytes?n=10") }))
        t.eq(r.status, 200)
        t.eq(r.body, "")
        t.eq(r.headers["content-length"], "10")
      end)

      t.it("sends headers exactly, adds no Expect or form content type", function()
        local value = "Bearer " .. SECRET .. ' "q" \\ é'
        local e = echo(tr, {
          method = "POST",
          url = url("/_dl/echo"),
          headers = { authorization = value, ["x-empty"] = "", ["X-Mixed"] = "v" },
          body = "x",
        })
        t.eq(e.headers.authorization, value)
        t.eq(e.headers["x-empty"], "")
        t.eq(e.headers["x-mixed"], "v")
        t.eq(e.headers.expect, nil)
        t.eq(e.headers["content-type"], nil)
        t.eq(e.headers["content-length"], "1")
      end)

      t.it("keeps the path and query exactly", function()
        local e =
          echo(tr, { method = "GET", url = url("/_dl/echo/a%2Fb/%C3%A9?x=1&x=2&y=%20&z[]=3") })
        t.eq(e.path, "/_dl/echo/a%2Fb/%C3%A9")
        t.eq(e.query, "x=1&x=2&y=%20&z[]=3")
      end)

      t.it("sends and receives JSON", function()
        local body =
          json.encode({ name = "proj é ✓", n = 1.5, list = json.array({}), null = json.null })
        local e = echo(tr, {
          method = "POST",
          url = url("/_dl/echo"),
          headers = { ["content-type"] = "application/json" },
          body = body,
        })
        t.eq(e.body, body)
        t.eq(e.headers["content-type"], "application/json")
        local r = ok(tr({ method = "GET", url = url("/_dl/status/201") }))
        t.eq(r.status, 201)
        t.same(json.decode(r.body), { status = 201 })
        t.eq(r.headers["content-type"], "application/json")
      end)

      t.it("sends and receives binary bytes exactly (all 256 values)", function()
        local bytes = serve.pattern_bytes(256 * 3 + 7)
        local r = ok(tr({
          method = "PUT",
          url = url("/_dl/mirror"),
          headers = { ["content-type"] = "application/octet-stream" },
          body = bytes,
        }))
        t.truthy(r.body == bytes, "mirrored bytes")
        local g = ok(tr({ method = "GET", url = url("/_dl/bytes?n=1000") }))
        t.truthy(g.body == serve.pattern_bytes(1000), "downloaded bytes")
      end)

      t.it("handles empty bodies both ways", function()
        local e = echo(tr, { method = "POST", url = url("/_dl/echo"), body = "" })
        t.eq(e.body_length, 0)
        t.eq(e.headers["content-length"], "0")
        local g = echo(tr, { method = "GET", url = url("/_dl/echo") })
        t.eq(g.headers["content-length"], nil)
        s.script("/" .. key .. "/empty", { { status = 204 }, { status = 200, body = "" } })
        local r1 = ok(tr({ method = "DELETE", url = url("/" .. key .. "/empty") }))
        t.eq(r1.status, 204)
        t.eq(r1.body, "")
        local r2 = ok(tr({ method = "GET", url = url("/" .. key .. "/empty") }))
        t.eq(r2.status, 200)
        t.eq(r2.body, "")
      end)

      t.it("returns error statuses with their bodies (no --fail), redirects unfollowed", function()
        s.script("/" .. key .. "/codes", {
          { status = 404, json = { message = "no such project" } },
          { status = 500, body = "boom" },
          { status = 503, headers = { ["Retry-After"] = "2" }, body = "later" },
          { status = 302, headers = { Location = "/elsewhere" }, body = "" },
        })
        local path = url("/" .. key .. "/codes")
        local r = ok(tr({ method = "GET", url = path }))
        t.eq(r.status, 404)
        t.same(json.decode(r.body), { message = "no such project" })
        r = ok(tr({ method = "GET", url = path }))
        t.eq(r.status, 500)
        t.eq(r.body, "boom")
        r = ok(tr({ method = "GET", url = path }))
        t.eq(r.status, 503)
        t.eq(r.headers["retry-after"], "2")
        r = ok(tr({ method = "GET", url = path }))
        t.eq(r.status, 302)
        t.eq(r.headers.location, "/elsewhere")
      end)

      t.it("lowercases response headers and joins repeats; skips 100 Continue", function()
        s.script("/" .. key .. "/hdrs", {
          {
            status = 200,
            continue = true,
            headers = { { "X-Multi", "a" }, { "X-Multi", "b" }, { "X-Mixed-Case", "v" } },
            body = "ok",
          },
        })
        local r = ok(tr({ method = "GET", url = url("/" .. key .. "/hdrs") }))
        t.eq(r.status, 200)
        t.eq(r.headers["x-multi"], "a, b")
        t.eq(r.headers["x-mixed-case"], "v")
        t.eq(r.body, "ok")
      end)

      t.it("non-ASCII in headers and bodies", function()
        local text = "naïve 日本語 🎉"
        local r = ok(tr({
          method = "POST",
          url = url("/_dl/mirror"),
          headers = { ["content-type"] = "text/plain; charset=utf-8", ["x-note"] = text },
          body = text,
        }))
        t.eq(r.body, text)
        local e =
          echo(tr, { method = "GET", url = url("/_dl/echo"), headers = { ["x-note"] = text } })
        t.eq(e.headers["x-note"], text)
      end)

      t.it("times out with TransportError, err.timeout = true", function()
        local start = os.time()
        local e = t.fails_with(
          "TransportError",
          tr({ method = "GET", url = url("/_dl/slow?delay=4"), timeout = 0.5 })
        )
        t.eq(e.timeout, true)
        t.truthy(os.time() - start <= 3, "returned well before the server answered")
      end)

      t.it("a refused connection is TransportError, not a timeout, with no secret", function()
        local e = t.fails_with(
          "TransportError",
          tr({
            method = "GET",
            url = "http://127.0.0.1:1/x?api_key=" .. SECRET,
            headers = { authorization = "Bearer " .. SECRET },
          })
        )
        t.eq(e.curl_code, 7)
        t.falsy(e.timeout)
        t.no_match(tostring(e), SECRET, true)
      end)

      t.it("follows redirects only when asked (follow_redirects = true)", function()
        local follow = key == "popen" and popen_curl({ follow_redirects = true })
          or exec_curl(REX and REX.exec or serve.popen_exec, { follow_redirects = true })
        s.script("/" .. key .. "/redir", {
          { status = 302, headers = { Location = "/_dl/echo/landed" }, body = "" },
        })
        local r = ok(follow({ method = "GET", url = url("/" .. key .. "/redir") }))
        t.eq(r.status, 200)
        t.eq(json.decode(r.body).path, "/_dl/echo/landed")
      end)

      t.it("a TLS failure (https to a plain HTTP port) is TransportError with err.tls", function()
        local https = string.gsub(BASE, "^http:", "https:")
        local e = t.fails_with(
          "TransportError",
          tr({ method = "GET", url = https .. "/_dl/echo", timeout = 5 })
        )
        t.eq(e.tls, true)
        t.falsy(e.timeout)
      end)

      t.it("a dropped connection is TransportError", function()
        s.script("/" .. key .. "/drop", { { drop = true } })
        local e =
          t.fails_with("TransportError", tr({ method = "GET", url = url("/" .. key .. "/drop") }))
        t.truthy(e.curl_code == 52 or e.curl_code == 56, "curl code " .. tostring(e.curl_code))
      end)

      t.it("moves 5 MB each way", function()
        local big = string.rep("0123456789abcdef", 327680) -- 5 MiB
        local r = ok(tr({
          method = "POST",
          url = url("/_dl/mirror"),
          headers = { ["content-type"] = "application/octet-stream" },
          body = big,
        }))
        t.eq(#r.body, #big)
        t.truthy(r.body == big, "5 MiB mirrored")
        local g = ok(tr({ method = "GET", url = url("/_dl/bytes?n=5000000") }))
        t.eq(#g.body, 5000000)
        t.truthy(g.body == serve.pattern_bytes(5000000), "5 MB downloaded")
      end)

      t.it("the server saw what the transport sent (request log)", function()
        s.reset()
        tr({
          method = "PATCH",
          url = url("/" .. key .. "/log?q=1"),
          headers = { ["x-a"] = "1" },
          body = "{}",
        })
        local log = s.requests()
        t.eq(#log, 1)
        t.eq(log[1].method, "PATCH")
        t.eq(log[1].path, "/" .. key .. "/log")
        t.eq(log[1].query, "q=1")
        t.eq(log[1].headers["x-a"], "1")
        t.eq(log[1].body, "{}")
      end)
    end)
  end

  if not REX then
    t.describe("popen_curl temp files", function()
      -- a private TMPDIR, and a fake curl that records the mode of every file in it while
      -- it runs, then hands over to the real curl
      local function setup()
        local p = io.popen('mktemp -d "${TMPDIR:-/tmp}/dl-spec.XXXXXX"')
        local dir = string.match(p:read("*a"), "[^\n]+")
        p:close()
        local fake = dir .. "-curl.sh"
        local f = io.open(fake, "wb")
        f:write(
          "#!/bin/sh\n"
            .. "for x in '"
            .. dir
            .. "'/*; do ls -l \"$x\" | cut -c1-10 >> '"
            .. dir
            .. "-modes'; done\n"
            .. 'exec curl "$@"\n'
        )
        f:close()
        os.execute("chmod 700 '" .. fake .. "'")
        return dir, fake
      end
      local function list(dir)
        local p = io.popen("ls -A '" .. dir .. "'")
        local out = p:read("*a")
        p:close()
        return out
      end
      local function cleanup(dir)
        os.execute("rm -rf '" .. dir .. "' '" .. dir .. "-curl.sh' '" .. dir .. "-modes'")
      end

      t.it("are 0600 while curl runs and gone afterwards, on success and failure", function()
        local dir, fake = setup()
        local tr = popen_curl({ tmpdir = dir, curl = fake })
        local r = tr({
          method = "POST",
          url = BASE .. "/_dl/echo",
          headers = { authorization = SECRET },
          body = "b",
        })
        t.truthy(r and r.status == 200, "request succeeded")
        t.eq(list(dir), "")
        local e = select(
          2,
          tr({ method = "GET", url = "http://127.0.0.1:1/", headers = { authorization = SECRET } })
        )
        t.eq(e and e.tag, "TransportError")
        t.eq(list(dir), "")
        local f = io.open(dir .. "-modes", "rb")
        local modes = f:read("*a")
        f:close()
        cleanup(dir)
        local n = 0
        for mode in string.gmatch(modes, "[^\n]+") do
          n = n + 1
          t.eq(mode, "-rw-------", "temp file mode")
        end
        t.eq(n, 5, "3 files for the POST (config, stderr, body), 2 for the GET")
      end)
    end)
  end
end

---------------------------------------------------------------------------------------
-- end to end: the full client (task 04) over real HTTP, asserting on the trace
---------------------------------------------------------------------------------------

local have_client = BASE and t.pcall(function()
  return require("distilled.client")
end)
if not BASE then
  t.describe("client end to end over HTTP", function()
    t.pending("skipped: DL_SERVE_URL is not set (run verify/dl test --http)")
  end)
elseif not have_client then
  t.describe("client end to end over HTTP", function()
    t.pending("skipped: distilled.client does not load yet (task 04)")
  end)
else
  local trace = require("distilled.trace")
  local expect = require("distilled.trace.expect")
  local fixtures = require("distilled.testing.fixtures")
  local Fake = serve.fixture_class()
  -- operation span names as the operation layer derives them (operation.info)
  local svc = fixtures.service()
  local function span_name(op)
    local info = require("distilled.operation").info(svc, svc.ops[op])
    return info.name
  end
  local GET_SPAN, LIST_SPAN = span_name("get_project"), span_name("list_projects")

  for _, entry in ipairs(transports()) do
    local tr, key = entry.tr, entry.key
    local s = serve.client(tr)
    local prefix = "/e2e-" .. key

    local function new_client()
      local mem = trace.exporters.memory()
      local sleeps = {}
      local client = Fake.new({
        api_key = SECRET,
        base_url = BASE .. prefix,
        transport = tr,
        sleep = function(sec)
          sleeps[#sleeps + 1] = sec
        end,
        tracing = { level = "debug", exporter = mem },
      })
      return client, mem, sleeps
    end

    local function requests_to(path)
      local out = {}
      for _, r in ipairs(s.requests()) do
        if r.path == path then
          out[#out + 1] = r
        end
      end
      return out
    end

    t.describe("client end to end over HTTP: " .. entry.name, function()
      t.it("retries 500, 500, then succeeds", function()
        s.reset()
        s.script(prefix .. "/projects/p1", {
          { status = 500, json = { message = "boom 1" } },
          { status = 500, json = { message = "boom 2" } },
          { status = 200, json = fixtures.bodies.project("p1") },
        })
        local client, mem, sleeps = new_client()
        local value = ok(client:get_project({ project_id = "p1" }))
        t.eq(value.project.id, "p1")
        t.eq(#sleeps, 2)
        local e = expect(mem)
        local op = e:span(GET_SPAN):ok()
        op:attr("http.response.status_code", 200)
        op:children("distilled.attempt"):count(3)
        e:spans("distilled.transport"):count(3)
        e:no_attr_contains(SECRET)
        local seen = requests_to(prefix .. "/projects/p1")
        t.eq(#seen, 3)
        for _, r in ipairs(seen) do
          t.eq(r.headers.authorization, "Bearer " .. SECRET)
          t.eq(r.method, "GET")
        end
        client:close()
      end)

      t.it("walks a cursor-paginated listing", function()
        s.reset()
        local page = fixtures.bodies.page
        s.script(prefix .. "/projects", {
          { status = 200, json = page({ "a", "b" }, "c1") },
          { status = 200, json = page({ "c" }, "c2") },
          { status = 200, json = page({}) },
        })
        local client, mem = new_client()
        local items = ok(client:list_projects_items({ limit = 2 }):collect())
        t.eq(#items, 3)
        t.eq(items[3].id, "c")
        local seen = requests_to(prefix .. "/projects")
        t.eq(#seen, 3)
        t.eq(seen[1].query, "limit=2")
        t.match(seen[2].query, "cursor=c1", true)
        t.match(seen[3].query, "cursor=c2", true)
        local e = expect(mem)
        e:spans(LIST_SPAN):count(3)
        e:no_attr_contains(SECRET)
        client:close()
      end)

      t.it("returns a typed error (404 NotFound) with trace id and status", function()
        s.reset()
        s.script(prefix .. "/projects/missing", {
          { status = 404, json = { code = "", message = "project not found" } },
        })
        local client, mem = new_client()
        local v, err = client:get_project({ project_id = "missing" })
        t.eq(v, nil)
        t.eq(err.tag, "NotFound")
        t.eq(err.status, 404)
        t.truthy(err.trace_id, "err.trace_id")
        t.no_match(tostring(err), SECRET, true)
        local e = expect(mem)
        e:span(GET_SPAN):failed("NotFound"):attr("http.response.status_code", 404)
        e:no_attr_contains(SECRET)
        t.eq(#requests_to(prefix .. "/projects/missing"), 1)
        client:close()
      end)

      t.it("a transport failure surfaces as TransportError through the client", function()
        local client = Fake.new({
          api_key = SECRET,
          base_url = "http://127.0.0.1:1",
          transport = tr,
          sleep = function() end,
          retry = "none",
        })
        local v, err = client:get_project({ project_id = "p1" })
        t.eq(v, nil)
        t.eq(err.tag, "TransportError")
        t.no_match(tostring(err), SECRET, true)
      end)
    end)
  end
end
