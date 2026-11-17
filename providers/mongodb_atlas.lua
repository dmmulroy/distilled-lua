-- MongoDB Atlas's provider spec.
--
-- Mirrors Distilled's hand-written MongoDB Atlas glue (packages/mongodb-atlas/src/):
-- - credentials.ts: OAuth 2.0 client credentials: MONGODB_ATLAS_CLIENT_ID and
--   MONGODB_ATLAS_CLIENT_SECRET are exchanged (HTTP Basic, form grant_type) at
--   {base}/api/oauth/token, the token refreshed 60 s before expires_in (default 3600 s);
--   or a given access token. The base URL from MONGODB_ATLAS_API_BASE_URL, default
--   https://cloud.mongodb.com.
-- - protocol.ts (its own decode): the message is detail | reason (else the text, else
--   HTTP <status>), matched without a code; 402 is PaymentRequired; the unknown error
--   carries errorCode, reason and detail.
-- - errors.ts: PaymentRequired, UnknownMongodbAtlasError, MongodbAtlasParseError.
return {
  name = "mongodb_atlas",
  title = "MongodbAtlas",
  base_url = {
    default = "https://cloud.mongodb.com",
    option = "base_url",
    env = "MONGODB_ATLAS_API_BASE_URL",
  },
  options = {
    access_token = { secret = true, doc = "an access token (instead of client credentials)" },
    client_id = { env = "MONGODB_ATLAS_CLIENT_ID" },
    client_secret = { secret = true, env = "MONGODB_ATLAS_CLIENT_SECRET" },
  },
  headers = { Authorization = "Bearer {access_token}" },
  oauth = {
    token_url = "{base_url}/api/oauth/token",
    client_id = "client_id",
    client_secret = "client_secret",
    into = "access_token",
    auth = "basic",
    default_ttl_s = 3600,
    refresh_window_s = 60,
    required = true,
    label = "OAuth2 token exchange",
  },
  error_envelope = { message = { "/detail", "/reason" } },
  unknown_fields = { errorCode = "/errorCode", reason = "/reason", detail = "/detail" },
  -- the Atlas model declares PaymentRequired too; its class is then the model's
  error_classes = { PaymentRequired = { categories = { "BadRequestError" } } },
  status_map = { [402] = "PaymentRequired" },
  unknown_tag = "UnknownMongodbAtlasError",
  parse_tag = "MongodbAtlasParseError",
}
