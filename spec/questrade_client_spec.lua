-- The generated Questrade client (clients/questrade/): access-token credentials, the
-- refresh-token redemption and its rotation (packages/questrade/src/credentials.ts), and
-- that the refresh token, which travels in the token URL's query, never reaches a
-- process argument through the curl transports. No network.
local t = require("spec.harness")
local common = require("distilled.transport.curl_common")
local exec_curl = require("distilled.transport.exec_curl")
local popen_curl = require("distilled.transport.popen_curl")
local testing = require("distilled.testing")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local Questrade = require("questrade")

local REX = rawget(_G, "rex")
local LOGIN = "https://login.questrade.com"
local seq = { n = 0 }

-- a refresh token no other case uses: the redemption cache is per process
local function fresh_token()
  seq.n = seq.n + 1
  return "RT-SPEC-FAKE-" .. seq.n .. "-x+y/z"
end

local function tokens(access, refresh, server, expires)
  return {
    status = 200,
    body = {
      access_token = access,
      token_type = "Bearer",
      expires_in = expires or 1800,
      refresh_token = refresh,
      api_server = server or "https://api05.iq.questrade.com/",
    },
  }
end

local function client(opts, responses)
  local host = testing.host({ responses = responses or {}, env = opts.env or {} })
  local o = { host = host, retry = "none" }
  for k, v in pairs(opts) do
    if k ~= "env" then
      o[k] = v
    end
  end
  return Questrade.new(o), host
end

t.describe("questrade: access-token credentials", function()
  t.it("QUESTRADE_ACCESS_TOKEN with QUESTRADE_API_SERVER (trimmed of / and /v1)", function()
    local c, host = client({
      env = {
        QUESTRADE_ACCESS_TOKEN = "AT-SPEC-FAKE",
        QUESTRADE_API_SERVER = "https://api01.iq.questrade.com/v1/",
      },
    }, { { status = 200, body = { time = "2024-01-01T00:00:00.000000-05:00" } } })
    local res, err = c:get_time({})
    t.eq(err, nil)
    t.eq(res.time, "2024-01-01T00:00:00.000000-05:00")
    t.eq(#host.requests, 1, "no redemption")
    t.eq(host.requests[1].url, "https://api01.iq.questrade.com/v1/time")
    t.eq(host.requests[1].headers.authorization, "Bearer AT-SPEC-FAKE")
  end)

  t.it("neither form is a ConfigError naming both", function()
    local c, host = client({ env = { QUESTRADE_ACCESS_TOKEN = "AT-ONLY" } })
    local _, err = c:get_time({})
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "QUESTRADE_REFRESH_TOKEN, or QUESTRADE_ACCESS_TOKEN with", true)
    t.eq(#host.requests, 0)
  end)

  t.it("failures are { code, message }: the status class, then UnknownQuestradeError", function()
    local c = client({ access_token = "AT", api_server = "https://api01.iq.questrade.com" }, {
      { status = 401, body = { code = 1017, message = "Access token is invalid" } },
      { status = 418, body = { code = 1, message = "odd" } },
    })
    local _, err = c:get_time({})
    t.eq(err.tag, "Unauthorized")
    t.eq(err.message, "Access token is invalid")
    t.eq(err.code, 1017)
    _, err = c:get_time({})
    t.eq(err.tag, "UnknownQuestradeError")
    t.eq(err.code, "1")
  end)
end)

t.describe("questrade: refresh-token redemption", function()
  t.it("redeems once, uses the token's API server, reuses the access token", function()
    local rt = fresh_token()
    local c, host = client({ env = { QUESTRADE_REFRESH_TOKEN = rt } }, {
      tokens("AT-1", "RT-NEXT-1"),
      { status = 200, body = { accounts = {} } },
      { status = 200, body = { accounts = {} } },
    })
    local _, err = c:list_accounts({})
    t.eq(err, nil)
    c:list_accounts({})
    local r = host.requests
    t.eq(#r, 3)
    t.eq(r[1].method, "GET")
    t.eq(
      r[1].url,
      LOGIN
        .. "/oauth2/token?grant_type=refresh_token&refresh_token="
        .. string.gsub(string.gsub(rt, "%+", "%%2B"), "/", "%%2F")
    )
    t.eq(r[1].headers.accept, "application/json")
    t.eq(r[1].headers.authorization, nil)
    t.eq(r[2].url, "https://api05.iq.questrade.com/v1/accounts")
    t.eq(r[2].headers.authorization, "Bearer AT-1")
    t.eq(r[3].headers.authorization, "Bearer AT-1")
  end)

  t.it("redeems the rotated refresh token 60 s before expiry", function()
    local rt = fresh_token()
    local c, host = client(
      { refresh_token = rt, login_url = "https://practicelogin.questrade.com/x" },
      {
        tokens("AT-1", "RT-ROTATED", "https://api07.iq.questrade.com", 1800),
        { status = 200, body = {} },
        tokens("AT-2", "RT-ROTATED-2", "https://api08.iq.questrade.com", 1800),
        { status = 200, body = {} },
      }
    )
    c:list_accounts({})
    host.advance(1800 - 60 - 1)
    t.eq(#host.requests, 2)
    host.advance(1)
    c:list_accounts({})
    local r = host.requests
    t.eq(#r, 4)
    t.match(r[1].url, "^https://practicelogin%.questrade%.com/oauth2/token%?")
    t.match(r[3].url, "refresh_token=RT%-ROTATED$")
    t.eq(r[4].url, "https://api08.iq.questrade.com/v1/accounts")
    t.eq(r[4].headers.authorization, "Bearer AT-2")
  end)

  t.it("a refused redemption is a ConfigError that names neither token nor body", function()
    local rt = fresh_token()
    local c, host = client({ refresh_token = rt }, {
      { status = 400, body = "<html>Bad Request " .. rt .. "</html>" },
    })
    local _, err = c:list_accounts({})
    t.eq(err.tag, "ConfigError")
    t.eq(err.key, "refresh_token")
    t.match(err.message, "answered 400", true)
    t.match(err.message, "redeems once", true)
    t.no_match(err.message, rt, true)
    t.no_match(err.message, "html", true)
    t.eq(#host.requests, 1)
  end)

  t.it("an answer without the tokens is a ConfigError", function()
    local c = client({ refresh_token = fresh_token() }, {
      { status = 200, body = { access_token = "AT" } },
    })
    local _, err = c:list_accounts({})
    t.eq(err.tag, "ConfigError")
    t.match(err.message, "no access_token, refresh_token or api_server", true)
    c = client({ refresh_token = fresh_token() }, { { status = 200, body = "not json" } })
    _, err = c:list_accounts({})
    t.match(err.message, "not JSON", true)
  end)

  t.it("a transport failure is a ConfigError without the token", function()
    local rt = fresh_token()
    local c = client({ refresh_token = rt }, {
      require("distilled.errors").new("TransportError", {
        message = "curl: (6) Could not resolve host for /oauth2/token?refresh_token=" .. rt,
      }),
    })
    local _, err = c:list_accounts({})
    t.eq(err.tag, "ConfigError")
    t.no_match(err.message, rt, true)
    t.match(err.message, "<redacted>", true)
  end)
end)

t.describe("questrade: the refresh token stays out of process arguments", function()
  local function curl_output(head, body, status)
    return head .. body .. "\n" .. common.TRAILER .. " " .. (status or 200) .. " " .. #body
  end
  local HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"

  t.it("exec_curl: the token URL travels in curl's config on stdin, not in argv", function()
    local rt = fresh_token()
    local calls = {}
    local answers = {
      '{"access_token":"AT-X","refresh_token":"RT-Y","api_server":"https://api01.iq.questrade.com","expires_in":1800}',
      '{"accounts":[]}',
    }
    local exec = function(argv, opts)
      calls[#calls + 1] = { argv = argv, opts = opts }
      local body = answers[#calls]
      return { code = 0, ok = true, stdout = curl_output(HEAD, body), stderr = "" }
    end
    local c = Questrade.new({
      refresh_token = rt,
      transport = exec_curl(exec),
      getenv = function()
        return nil
      end,
      retry = "none",
    })
    local _, err = c:list_accounts({})
    t.eq(err, nil)
    t.eq(#calls, 2)
    for i, call in ipairs(calls) do
      for _, arg in ipairs(call.argv) do
        t.no_match(arg, rt, true)
        t.no_match(arg, "oauth2", true)
        t.no_match(arg, "AT-X", true)
      end
      t.truthy(call.opts.stdin and #call.opts.stdin > 0, "config on stdin " .. i)
    end
    t.match(
      calls[1].opts.stdin,
      "refresh_token=" .. string.gsub(string.gsub(rt, "%+", "%%2B"), "/", "%%2F"),
      true
    )
    t.match(calls[2].opts.stdin, "Bearer AT-X", true)
  end)

  t.it("popen_curl: the shell command names only temp file paths (lua, luajit)", function()
    if REX then
      return t.pending("io.popen raises in gopher-lua; exec_curl covers Rex")
    end
    local rt = fresh_token()
    local real = io.popen
    local commands, configs = {}, {}
    local answers = {
      '{"access_token":"AT-P","refresh_token":"RT-Q","api_server":"https://api01.iq.questrade.com","expires_in":1800}',
      '{"accounts":[]}',
    }
    local n = { v = 0 }
    io.popen = function(cmd, mode)
      commands[#commands + 1] = cmd
      if string.find(cmd, "--config", 1, true) then
        -- the curl run: read the config it was given, answer for curl
        local path = string.match(cmd, "%-%-config '([^']+)'")
        local f = io.open(path, "rb")
        configs[#configs + 1] = f and f:read("*a") or ""
        if f then
          f:close()
        end
        n.v = n.v + 1
        local out = curl_output(HEAD, answers[n.v]) .. "\n0"
        return {
          read = function()
            return out
          end,
          close = function()
            return true
          end,
        }
      end
      return real(cmd, mode)
    end
    local ok, res, err = t.pcall(function()
      local c = Questrade.new({
        refresh_token = rt,
        transport = popen_curl(),
        getenv = function()
          return nil
        end,
        retry = "none",
      })
      return c:list_accounts({})
    end)
    io.popen = real
    t.truthy(ok, tostring(res))
    t.eq(err, nil)
    t.eq(#configs, 2)
    for _, cmd in ipairs(commands) do
      t.no_match(cmd, rt, true)
      t.no_match(cmd, "oauth2", true)
      t.no_match(cmd, "AT-P", true)
    end
    t.match(configs[1], "refresh_token=", true)
    t.match(configs[2], "Bearer AT-P", true)
  end)
end)
