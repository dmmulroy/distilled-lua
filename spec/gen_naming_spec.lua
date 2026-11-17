local t = require("spec.harness")
local naming = require("distilled.gen.naming")

t.describe("gen.naming: snake_case operation names", function()
  -- The written-down cases: acronyms, digits, mixed-case words.
  local CASES = {
    { "GetProject", "get_project" },
    { "ListProjects", "list_projects" },
    { "GetOAuthClient", "get_oauth_client" },
    { "ListIPAllowlist", "list_ip_allowlist" },
    { "GetV2Thing", "get_v2_thing" },
    { "GetConsumptionHistoryPerProjectV2", "get_consumption_history_per_project_v2" },
    { "AddProjectJWKS", "add_project_jwks" },
    { "GetProjectBranchDataAPI", "get_project_branch_data_api" },
    { "CreateNeonAuthProviderSDKKeys", "create_neon_auth_provider_sdk_keys" },
    { "GetConnectionURI", "get_connection_uri" },
    { "CreateNeonAuthOAuthClient", "create_neon_auth_oauth_client" },
    { "RotateNeonAuthOAuthClientSecret", "rotate_neon_auth_oauth_client_secret" },
    { "ListOrganizationVPCEndpointsAllRegions", "list_organization_vpc_endpoints_all_regions" },
    { "GetNeonAuthOauthProviderPlugin", "get_neon_auth_oauth_provider_plugin" },
    { "getProject", "get_project" },
    { "Apps_list", "apps_list" },
    { "GetIPv4Address", "get_ipv4_address" },
    { "Get2Things", "get2_things" },
    { "URL", "url" },
    { "A", "a" },
  }
  for _, c in ipairs(CASES) do
    t.it(c[1] .. " -> " .. c[2], function()
      t.eq(naming.snake_case(c[1]), c[2])
    end)
  end

  t.it("a provider word joins the defaults", function()
    t.eq(naming.snake_case("GetGitHubRepo"), "get_git_hub_repo")
    t.eq(naming.snake_case("GetGitHubRepo", naming.words({ "GitHub" })), "get_github_repo")
  end)
end)

t.describe("gen.naming: operation_names", function()
  t.it("names every operation", function()
    local names = naming.operation_names({
      { id = "a#GetProject", name = "GetProject" },
      { id = "a#ListProjects", name = "ListProjects", paginated = true },
    })
    t.same(names, { ["a#GetProject"] = "get_project", ["a#ListProjects"] = "list_projects" })
  end)

  t.it("fails when two operations collide after snake-casing", function()
    local names, err = naming.operation_names({
      { id = "a#GetIPList", name = "GetIPList" },
      { id = "a#GetIpList", name = "GetIpList" },
    })
    t.eq(names, nil)
    t.match(err, "GetIPList and GetIpList are both get_ip_list", true)
  end)

  t.it("a sibling that would take a real operation's name becomes _all_pages/_all_items", function()
    -- Exa: ListWebsets (paginated) and the operation ListWebsetsItems; the operation keeps
    -- Distilled's name, the sibling moves (whatever the order of the operations)
    for _, ops in ipairs({
      {
        { id = "a#ListThings", name = "ListThings", paginated = true },
        { id = "a#ListThingsItems", name = "ListThingsItems" },
      },
      {
        { id = "a#ListThingsItems", name = "ListThingsItems" },
        { id = "a#ListThings", name = "ListThings", paginated = true },
      },
    }) do
      local names, err, pages = naming.operation_names(ops)
      t.eq(err, nil)
      t.same(
        names,
        { ["a#ListThings"] = "list_things", ["a#ListThingsItems"] = "list_things_items" }
      )
      t.same(pages, {
        ["a#ListThings"] = { pages = "list_things_pages", items = "list_things_all_items" },
      })
    end
  end)

  t.it("fails when the renamed sibling collides too, naming both", function()
    local names, err = naming.operation_names({
      { id = "a#ListThings", name = "ListThings", paginated = true },
      { id = "a#ListThingsItems", name = "ListThingsItems" },
      { id = "a#ListThingsAllItems", name = "ListThingsAllItems" },
    })
    t.eq(names, nil)
    t.match(err, "ListThingsAllItems and ListThings (_items) are both list_things_all_items", true)
  end)

  t.it("returns the default sibling names of paginated operations", function()
    local _, _, pages = naming.operation_names({
      { id = "a#ListThings", name = "ListThings", paginated = true },
      { id = "a#GetThing", name = "GetThing" },
    })
    t.same(
      pages,
      { ["a#ListThings"] = { pages = "list_things_pages", items = "list_things_items" } }
    )
  end)

  t.it("fails on a Lua keyword, and an override fixes it", function()
    local names, err = naming.operation_names({ { id = "a#End", name = "End" } })
    t.eq(names, nil)
    t.match(err, "Lua keyword end", true)
    names = naming.operation_names(
      { { id = "a#End", name = "End" } },
      { overrides = { End = "finish" } }
    )
    t.same(names, { ["a#End"] = "finish" })
  end)

  t.it("fails on the client's own method names", function()
    local _, err = naming.operation_names({ { id = "a#With", name = "With" } })
    t.match(err, "every client already has", true)
    _, err = naming.operation_names({ { id = "a#Close", name = "Close" } })
    t.match(err, "close", true)
  end)

  t.it("treats goto and global as keywords on every runtime", function()
    t.falsy(naming.is_identifier("goto"))
    t.falsy(naming.is_identifier("global"))
    t.truthy(naming.is_identifier("get_project"))
    t.falsy(naming.is_identifier("2x"))
  end)
end)

t.describe("gen.naming: helpers", function()
  t.it("nearest suggests close names", function()
    local got = naming.nearest("get_projct", { "list_projects", "get_project", "delete_project" })
    t.eq(got[1], "get_project")
    got = naming.nearest("projects", { "list_projects", "get_project", "count_projects" })
    t.same(got, { "list_projects", "count_projects", "get_project" })
  end)

  t.it("summary takes the first paragraph on one line", function()
    t.eq(naming.summary("Get a thing\n\nReturns it."), "Get a thing")
    t.eq(naming.summary("One\nline  wraps"), "One line wraps")
    t.eq(naming.summary(nil), nil)
  end)

  t.it("local_name and is_prelude", function()
    t.eq(naming.local_name("com.neon.api#GetProject"), "GetProject")
    t.truthy(naming.is_prelude("smithy.api#String"))
    t.falsy(naming.is_prelude("com.neon.api#String"))
  end)
end)
