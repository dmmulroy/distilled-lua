-- Hugging Face's provider spec.
--
-- Mirrors Distilled's hand-written Hugging Face glue (packages/huggingface/src/):
-- - credentials.ts: the token from HF_TOKEN; the base URL from HF_API_URL, default
--   https://huggingface.co.
-- - protocol.ts: bearer auth; failures are { error = text } or { error = { code,
--   message } }.
-- - errors.ts: UnknownHuggingFaceError, HuggingFaceParseError.
return {
  name = "huggingface",
  title = "HuggingFace",
  base_url = { default = "https://huggingface.co", option = "base_url", env = "HF_API_URL" },
  auth = { kind = "bearer", from = "token", env = "HF_TOKEN" },
  error_envelope = { code = "/error/code", message = { "/error", "/error/message" } },
  unknown_tag = "UnknownHuggingFaceError",
  parse_tag = "HuggingFaceParseError",
}
