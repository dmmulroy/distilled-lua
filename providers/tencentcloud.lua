-- Tencent Cloud's provider spec: one spec for the package's 263 models (one module per
-- product, `require("tencentcloud.cvm")`, as Distilled's one TS module per product).
--
-- Mirrors Distilled's hand-written Tencent Cloud glue (packages/tencentcloud/src/):
-- - protocol.ts, signer.ts, region.ts: lua/distilled/protocol/tencentcloud.lua and
--   lua/distilled/tencentcloud/signer.lua (API 3.0: POST https://<service>.<root_domain>/,
--   X-TC-* headers, TC3-HMAC-SHA256).
-- - credentials.ts: TENCENTCLOUD_SECRET_ID, TENCENTCLOUD_SECRET_KEY,
--   TENCENTCLOUD_SESSION_TOKEN, TENCENTCLOUD_REGION (the protocol's client options).
-- - errors.ts: lua/distilled/tencentcloud/errors.lua (the common codes),
--   UnknownTencentCloudError, TencentCloudParseError.
-- - scripts/generate.ts: the com.tencentcloud#action trait (here: rpc.trait), wire member
--   names (`InstanceIds`, `Limit`), no pagination.
return {
  name = "tencentcloud",
  title = "TencentCloud",
  unknown_tag = "UnknownTencentCloudError",
  parse_tag = "TencentCloudParseError",
  naming = { members = "wire" },
  rpc = {
    protocol = "distilled.protocol.tencentcloud",
    trait = "com.tencentcloud#action",
    fields = { "service", "version", "action" },
  },
}
