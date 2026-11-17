-- Notion's provider spec.
--
-- Mirrors Distilled's hand-written Notion glue (packages/notion/src/):
-- - credentials.ts: the token from NOTION_TOKEN; the base URL from NOTION_API_BASE_URL,
--   default https://api.notion.com; the version from NOTION_VERSION, default 2026-03-11.
-- - protocol.ts: bearer auth, Notion-Version; 529 is ServiceUnavailable.
-- - errors.ts: UnknownNotionError, NotionParseError.
return {
  name = "notion",
  title = "Notion",
  base_url = {
    default = "https://api.notion.com",
    option = "base_url",
    env = "NOTION_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "token", env = "NOTION_TOKEN" },
  options = { notion_version = { env = "NOTION_VERSION", default = "2026-03-11" } },
  headers = { ["Notion-Version"] = "{notion_version}" },
  status_map = { [529] = "ServiceUnavailable" },
  unknown_tag = "UnknownNotionError",
  parse_tag = "NotionParseError",
}
