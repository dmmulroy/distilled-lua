-- Render's provider spec (class A: the classic keys only).
--
-- Mirrors Distilled's hand-written Render glue (packages/render/src/):
-- - credentials.ts: the key from RENDER_API_KEY; the base URL from RENDER_API_BASE_URL,
--   default https://api.render.com/v1.
-- - protocol.ts: bearer auth; the default { code, message } envelope; Accept: application/json (the runtime sends it). pagination.ts (paginateRender, cursor per item) is task 12's.
-- - errors.ts: UnknownRenderError, RenderParseError.
return {
  name = "render",
  title = "Render",
  base_url = {
    default = "https://api.render.com/v1",
    option = "base_url",
    env = "RENDER_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "api_key", env = "RENDER_API_KEY" },
  unknown_tag = "UnknownRenderError",
  parse_tag = "RenderParseError",
}
