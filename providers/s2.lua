-- S2's provider spec.
--
-- Mirrors Distilled's hand-written S2 glue (packages/s2/src/):
-- - credentials.ts: the token from S2_ACCESS_TOKEN; the basin from S2_BASIN; the account
--   endpoint from S2_ACCOUNT_ENDPOINT, default https://a.s2.dev/v1; the basin endpoint
--   from S2_BASIN_ENDPOINT, default https://{basin}.b.s2.dev/v1.
-- - protocol.ts: bearer auth; /streams and /streams/... are basin-scoped (the basin
--   endpoint, a basin required), every other route uses the account endpoint
--   (glue/s2.lua); 408 RequestTimeout, 412 PreconditionFailed, 416 RangeNotSatisfiable.
-- - pagination.ts (paginateStartAfter) is task 12's.
-- - errors.ts: RequestTimeout, PreconditionFailed, RangeNotSatisfiable, UnknownS2Error,
--   S2ParseError.
return {
  name = "s2",
  title = "S2",
  base_url = {
    default = "https://a.s2.dev/v1",
    option = "account_endpoint",
    env = "S2_ACCOUNT_ENDPOINT",
  },
  auth = { kind = "bearer", from = "token", env = "S2_ACCESS_TOKEN" },
  options = {
    basin = { env = "S2_BASIN", doc = "the basin of the stream operations" },
    basin_endpoint = { env = "S2_BASIN_ENDPOINT", default = "https://{basin}.b.s2.dev/v1" },
  },
  error_classes = {
    RequestTimeout = { categories = { "RetryableError" }, retryable = true },
    PreconditionFailed = { categories = { "ConflictError" } },
    RangeNotSatisfiable = { categories = { "BadRequestError" } },
  },
  status_map = {
    [408] = "RequestTimeout",
    [412] = "PreconditionFailed",
    [416] = "RangeNotSatisfiable",
  },
  glue = "glue/s2.lua",
  unknown_tag = "UnknownS2Error",
  parse_tag = "S2ParseError",
}
