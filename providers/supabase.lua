-- Supabase Management API's provider spec.
--
-- Mirrors Distilled's hand-written Supabase glue (packages/supabase/src/):
-- - credentials.ts: the token from SUPABASE_ACCESS_TOKEN; base URL
--   https://api.supabase.com (an option only).
-- - protocol.ts (its own decode): the message is `message` only (else the text, else
--   HTTP <status>), matched without a code; "active free projects" in it is
--   FreeProjectLimitReached; 406 is read as 404 (glue/supabase.lua); the unknown error
--   has no code.
-- - errors.ts: FreeProjectLimitReached (quota), UnknownSupabaseError, SupabaseParseError.
--
-- Not mirrored: form-urlencoded request bodies (operations whose http trait says
-- application/x-www-form-urlencoded): request.build sends JSON. 406 is NotFound, but
-- the operation's typed matchers still see 406.
return {
  name = "supabase",
  title = "Supabase",
  base_url = { default = "https://api.supabase.com", option = "base_url" },
  auth = { kind = "bearer", from = "access_token", env = "SUPABASE_ACCESS_TOKEN" },
  error_envelope = { message = "/message" },
  glue = "glue/supabase.lua",
  unknown_tag = "UnknownSupabaseError",
  parse_tag = "SupabaseParseError",
}
