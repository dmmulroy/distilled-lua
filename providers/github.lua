-- GitHub's provider spec (the REST API; the GraphQL part is another protocol).
--
-- Mirrors Distilled's hand-written GitHub glue (packages/github/src/):
-- - credentials.ts: the token from GITHUB_TOKEN, else GH_TOKEN; the base URL from
--   GITHUB_API_URL, default https://api.github.com; the User-Agent from
--   GITHUB_USER_AGENT, default distilled.cloud-github (GitHub requires one).
-- - protocol.ts: bearer auth, Accept application/vnd.github+json, X-GitHub-Api-Version
--   2022-11-28; failures are { message, errors = [{ code }] }; 410 is Gone;
--   rateLimited turns a 403/429 rate-limit answer into TooManyRequests
--   (glue/github.lua); the unknown error keeps the headers.
-- - errors.ts: Gone, UnknownGithubError, GithubParseError.
--
-- Not mirrored: paceWrites (an opt-in write interval), the fresh-token 401 retry and
-- GitHub App auth (app.ts, an RS256 JWT: task 14).
return {
  name = "github",
  title = "Github",
  base_url = { default = "https://api.github.com", option = "base_url", env = "GITHUB_API_URL" },
  auth = { kind = "bearer", from = "token", env = { "GITHUB_TOKEN", "GH_TOKEN" } },
  headers = {
    Accept = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
  },
  user_agent = { default = "distilled.cloud-github", env = "GITHUB_USER_AGENT" },
  error_envelope = { code = "/errors/0/code", message = "/message" },
  error_classes = { Gone = { categories = { "NotFoundError" } } },
  status_map = { [410] = "Gone" },
  glue = "glue/github.lua",
  unknown_tag = "UnknownGithubError",
  parse_tag = "GithubParseError",
}
