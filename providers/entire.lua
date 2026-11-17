-- Entire's provider spec (45 models: the Core and cell APIs).
--
-- Mirrors Distilled's hand-written Entire glue (packages/entire/src/):
-- - credentials.ts: the token from ENTIRE_TOKEN; the Core base URL from
--   ENTIRE_CORE_BASE_URL, default https://us.console.entire.io; the cell base URL from
--   ENTIRE_API_BASE_URL, default https://aws-us-east-2.api.entire.io.
-- - protocol.ts: bearer auth; failures are problem documents: message = detail | error
--   | title, then "location: message" for each of `errors`, joined by "; "; code =
--   code | title (glue/entire.lua); 410 Gone, 412 PreconditionFailed, 413
--   PayloadTooLarge, 421 MisdirectedRequest, 428 PreconditionRequired.
-- - scripts/generate.ts: com.entire.core.* models use EntireCoreProtocol (Core base
--   URL), com.entire.cell.* EntireCellProtocol.
-- - errors.ts: the five classes, UnknownEntireError, EntireParseError.
--
-- The Core models need task 10's per-model override, once merged:
--   models = { override = { <core model> = { base_url = { option = "core_base_url",
--     env = "ENTIRE_CORE_BASE_URL", default = "https://us.console.entire.io" } } } }
return {
  name = "entire",
  title = "Entire",
  base_url = {
    default = "https://aws-us-east-2.api.entire.io",
    option = "base_url",
    env = "ENTIRE_API_BASE_URL",
  },
  auth = { kind = "bearer", from = "token", env = "ENTIRE_TOKEN" },
  options = {
    core_base_url = { env = "ENTIRE_CORE_BASE_URL", default = "https://us.console.entire.io" },
  },
  error_classes = {
    Gone = { categories = { "NotFoundError" } },
    PreconditionFailed = { categories = { "ConflictError" } },
    PayloadTooLarge = { categories = { "BadRequestError" } },
    MisdirectedRequest = { categories = { "BadRequestError" } },
    PreconditionRequired = { categories = { "BadRequestError" } },
  },
  status_map = {
    [410] = "Gone",
    [412] = "PreconditionFailed",
    [413] = "PayloadTooLarge",
    [421] = "MisdirectedRequest",
    [428] = "PreconditionRequired",
  },
  glue = "glue/entire.lua",
  unknown_tag = "UnknownEntireError",
  parse_tag = "EntireParseError",
}
