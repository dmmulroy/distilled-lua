-- Apache Iceberg REST catalog's provider spec.
--
-- Mirrors Distilled's hand-written Iceberg glue (packages/iceberg/src/):
-- - credentials.ts: the catalog URI from ICEBERG_CATALOG_URI (required); the prefix from
--   ICEBERG_PREFIX; an optional token from ICEBERG_TOKEN.
-- - protocol.ts: bearer auth when a token is set; the base URL is <uri>/v1, plus
--   /<prefix> (slashes trimmed) except for /config (glue/iceberg.lua); failures are
--   { error = { code, message } }; 419 is AuthenticationTimeout.
-- - errors.ts: AuthenticationTimeout, UnknownIcebergError, IcebergParseError.
--
-- Not mirrored: fromCatalogConfig (reads the prefix and URI overrides from GET
-- /v1/config first): call get_config and pass its overrides as options.
return {
  name = "iceberg",
  title = "Iceberg",
  base_url = { option = "uri", env = "ICEBERG_CATALOG_URI" },
  auth = { kind = "bearer", from = "token", env = "ICEBERG_TOKEN", optional = true },
  options = { prefix = { env = "ICEBERG_PREFIX", doc = "the catalog prefix (from /v1/config)" } },
  error_envelope = { code = "/error/code", message = "/error/message" },
  error_classes = { AuthenticationTimeout = { categories = { "AuthError" } } },
  status_map = { [419] = "AuthenticationTimeout" },
  glue = "glue/iceberg.lua",
  unknown_tag = "UnknownIcebergError",
  parse_tag = "IcebergParseError",
}
