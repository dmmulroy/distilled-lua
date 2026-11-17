-- Trigger.dev's provider spec.
--
-- Mirrors Distilled's hand-written Trigger.dev glue (packages/trigger-dev/src/):
-- - credentials.ts: the key from TRIGGER_DEV_API_KEY, else TRIGGER_SECRET_KEY; the base
--   URL from TRIGGER_DEV_API_BASE_URL, default https://api.trigger.dev.
-- - protocol.ts: bearer auth.
-- - errors.ts: UnknownTriggerDevError, TriggerDevParseError.
return {
  name = "trigger_dev",
  title = "TriggerDev",
  base_url = {
    default = "https://api.trigger.dev",
    option = "base_url",
    env = "TRIGGER_DEV_API_BASE_URL",
  },
  auth = {
    kind = "bearer",
    from = "api_key",
    env = { "TRIGGER_DEV_API_KEY", "TRIGGER_SECRET_KEY" },
  },
  unknown_tag = "UnknownTriggerDevError",
  parse_tag = "TriggerDevParseError",
}
