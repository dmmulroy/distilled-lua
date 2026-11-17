-- distilled.azure.credentials: the Azure CLI and managed-identity token sources for an
-- Azure client's bearer_token option (additions; Distilled takes a pre-acquired token).
local t = require("spec.harness")
local json = require("distilled.json")
local testing = require("distilled.testing")
local azure_credentials = require("distilled.azure.credentials")

package.path = t.root .. "/clients/?.lua;" .. t.root .. "/clients/?/init.lua;" .. package.path

local TOKEN = "eyJ0eXAi-SPEC-token-9c1"

local function exec_answer(res)
  local calls = {}
  local exec = function(argv, opts)
    calls[#calls + 1] = { argv = argv, opts = opts }
    return res
  end
  return exec, calls
end

t.describe("azure credentials: cli", function()
  t.it("runs az account get-access-token through host.exec and returns stdout trimmed", function()
    local exec, calls = exec_answer({ ok = true, code = 0, stdout = TOKEN .. "\n", stderr = "" })
    local source = azure_credentials.cli({ tenant = "tenant-1" })
    local v = source({ exec = exec })
    t.eq(v, TOKEN)
    t.eq(
      table.concat(calls[1].argv, " "),
      "az account get-access-token --resource https://management.azure.com/"
        .. " --query accessToken --output tsv --tenant tenant-1"
    )
    t.eq(calls[1].opts.timeout, 30)
  end)

  t.it("a failing az is a ConfigError naming the exit code, never the output", function()
    local exec = exec_answer({ ok = false, code = 1, stdout = TOKEN, stderr = "ERROR: " .. TOKEN })
    local v, err = azure_credentials.cli()({ exec = exec })
    t.fails_with("ConfigError", v, err)
    t.match(err.message, "exited with code 1", true)
    t.no_match(err.message, TOKEN, true)
  end)

  t.it("a host without exec is a ConfigError", function()
    local v, err = azure_credentials.cli()({})
    t.fails_with("ConfigError", v, err)
  end)

  t.it("unknown options and wrong types raise (misuse)", function()
    t.raises(function()
      azure_credentials.cli({ resorce = "x" })
    end, "unknown option resorce")
    t.raises(function()
      azure_credentials.cli({ tenant = 1 })
    end, "must be a string")
  end)

  t.it("works as a client's bearer_token: the token is resolved once and sent", function()
    local Resources = require("azure.resources")
    local exec, calls = exec_answer({ ok = true, code = 0, stdout = TOKEN .. "\n" })
    local host = testing.host({
      responses = { { status = 200, body = "{}" }, { status = 200, body = "{}" } },
      exec = exec,
    })
    local c = Resources.new({
      host = host,
      retry = "none",
      bearer_token = azure_credentials.cli(),
      subscription_id = "s",
    })
    t.eq(select(2, c:get_resource_group({ resourceGroupName = "rg" })), nil)
    t.eq(select(2, c:get_resource_group({ resourceGroupName = "rg" })), nil)
    t.eq(#calls, 1)
    t.eq(host.requests[2].headers.authorization, "Bearer " .. TOKEN)
  end)
end)

t.describe("azure credentials: managed_identity", function()
  local function host_answer(answer, env)
    return testing.host({ responses = { answer }, env = env or {} })
  end

  t.it("asks the instance metadata service (IMDS) with Metadata: true", function()
    local host = host_answer({ status = 200, body = json.encode({ access_token = TOKEN }) })
    local v = azure_credentials.managed_identity({ client_id = "id-1" })(host)
    t.eq(v, TOKEN)
    local req = host.requests[1]
    t.eq(req.method, "GET")
    t.eq(
      req.url,
      "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"
        .. "&resource=https%3A%2F%2Fmanagement.azure.com%2F&client_id=id-1"
    )
    t.eq(req.headers.metadata, "true")
    t.eq(req.timeout, 10)
  end)

  t.it("uses IDENTITY_ENDPOINT and IDENTITY_HEADER when they are set (App Service)", function()
    local host = host_answer({ status = 200, body = json.encode({ access_token = TOKEN }) }, {
      IDENTITY_ENDPOINT = "http://127.0.0.1:41741/msi/token",
      IDENTITY_HEADER = "hdr-secret",
    })
    t.eq(azure_credentials.managed_identity()(host), TOKEN)
    local req = host.requests[1]
    t.eq(
      req.url,
      "http://127.0.0.1:41741/msi/token?api-version=2019-08-01"
        .. "&resource=https%3A%2F%2Fmanagement.azure.com%2F"
    )
    t.eq(req.headers["x-identity-header"], "hdr-secret")
  end)

  t.it("an error status is a ConfigError with the OAuth code only", function()
    local host = host_answer({
      status = 400,
      body = json.encode({
        error = "invalid_request",
        error_description = "Identity not found " .. TOKEN,
      }),
    })
    local v, err = azure_credentials.managed_identity()(host)
    t.fails_with("ConfigError", v, err)
    t.match(err.message, "answered 400 invalid_request", true)
    t.no_match(err.message, TOKEN, true)
  end)

  t.it("an answer without access_token, or no transport, is a ConfigError", function()
    local host = host_answer({ status = 200, body = "{}" })
    t.fails_with("ConfigError", azure_credentials.managed_identity()(host))
    t.fails_with("ConfigError", azure_credentials.managed_identity()({ getenv = os.getenv }))
  end)

  t.it("a transport failure is a ConfigError naming the endpoint", function()
    local host = {
      getenv = function()
        return nil
      end,
      transport = function()
        return nil, require("distilled.errors").new("TransportError", { message = "refused" })
      end,
    }
    local v, err = azure_credentials.managed_identity()(host)
    t.fails_with("ConfigError", v, err)
    t.match(err.message, "instance metadata service: refused", true)
  end)

  t.it("works as a client's bearer_token", function()
    local Resources = require("azure.resources")
    local host = testing.host({
      responses = {
        { status = 200, body = json.encode({ access_token = TOKEN }) },
        { status = 200, body = "{}" },
      },
    })
    local c = Resources.new({
      host = host,
      retry = "none",
      bearer_token = azure_credentials.managed_identity(),
      subscription_id = "s",
    })
    t.eq(select(2, c:get_resource_group({ resourceGroupName = "rg" })), nil)
    t.eq(host.requests[2].headers.authorization, "Bearer " .. TOKEN)
  end)
end)
