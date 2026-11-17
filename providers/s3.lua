-- Provider spec: Amazon S3 (task 25), `@distilled.cloud/s3`: clients/s3, require("s3").
--
-- Distilled generates packages/s3/src/services/s3.ts from the AWS spec mirror's S3 model
-- with packages/aws/patches/s3/ (packages/aws/scripts/generate.ts); here the model is
-- models/aws/s3.json (`verify/dl models sync aws`) and the generator reads everything
-- else from it (lua/distilled/gen/aws.lua): restXml, SigV4 name "s3", the endpoint rules
-- (virtual-hosted or path-style addressing), httpChecksum, the error traits. The runtime
-- is lua/distilled/aws/ (task 17); S3's presigning lives in lua/distilled/s3/.
--
--   bin/distilled-lua generate --model models/aws/s3.json --provider providers/s3.lua \
--     --out clients/s3
return {
  name = "s3",
  title = "S3",
  -- unused by AWS clients (the endpoint rules pick the URL); the spec format needs one
  base_url = { default = "https://s3.amazonaws.com" },
  auth = { kind = "none" },
  unknown_tag = "UnknownAwsError",
  -- Distilled's client-side parse failure is `ParseError` (s3/src/errors.ts), the same
  -- tag as the model's ParseError error shape; see STATUS.md (25) for the generator gap
  parse_tag = "S3ParseError",
  -- member names stay the Smithy names (Bucket, Key, ContinuationToken), as in Distilled
  naming = { members = "wire" },
  -- SelectObjectContent's event stream: emitted, fails with SdkError at call time
  allow_unsupported = { "streaming" },
}
