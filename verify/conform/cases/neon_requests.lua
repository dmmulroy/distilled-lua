-- Hand-written request cases for dl conform neon, appended to the generated ones.
-- Inputs are JSON-shaped Lua values (json.null for null, { ["$secret"] = v } for a secret).
local json = require("distilled.json")

return {
  { id = "get_project/label-dot", op = "get_project", input = { project_id = "." } },
  { id = "get_project/label-dotdot", op = "get_project", input = { project_id = ".." } },
  { id = "get_project/label-empty", op = "get_project", input = { project_id = "" } },
  { id = "get_project/label-missing", op = "get_project", input = json.object({}) },
  { id = "get_project/label-slashes", op = "get_project", input = { project_id = "../x/./y" } },
  { id = "get_project/label-number", op = "get_project", input = { project_id = 12 } },
  {
    id = "list_projects/big-numbers",
    op = "list_projects",
    input = { limit = 1e21, cursor = "c" },
  },
  {
    id = "list_projects/fraction",
    op = "list_projects",
    input = { limit = 0.000001, search = "\0nul" },
  },
  {
    id = "list_projects/bool-query",
    op = "list_projects",
    input = { limit = 10, search = "a&b=c", org_id = "o/1", timeout = 0 },
  },
  {
    id = "create_project/nulls",
    op = "create_project",
    input = { project = { name = json.null, settings = json.null } },
  },
  {
    id = "create_project/empty-project",
    op = "create_project",
    input = { project = json.object({}) },
  },
  {
    id = "create_project/extra-nested",
    op = "create_project",
    input = { project = { name = "n", zz_nested_extra = { a = json.array({}) } } },
  },
  {
    id = "create_project_branch_function_deployment/file",
    op = "create_project_branch_function_deployment",
    input = {
      project_id = "p1",
      branch_id = "b1",
      slug = "fn",
      zip = {
        ["$file"] = {
          b64 = "UEsDBAoAAAAA/w==",
          filename = 'my "fn".zip',
          content_type = "application/zip",
        },
      },
      runtime = "nodejs24",
      environment = { ["$secret"] = "KEY=value\nOTHER=2" },
    },
  },
  {
    id = "create_project_branch_function_deployment/text-crlf",
    op = "create_project_branch_function_deployment",
    input = { project_id = "p1", branch_id = "b1", slug = "fn", environment = "A=1\r\nB=2\rC=3\n" },
  },
}
