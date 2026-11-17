-- Provider spec: AWS (task 17). Every model in models/aws except S3 (task 25) and the
-- ses-events payload types (no operations): one client per service, require("aws.<model>").
--
-- AWS models are native Smithy: the generator reads the protocol, the SigV4 name, the
-- endpoint rules and the error traits from the model (lua/distilled/gen/aws.lua); the
-- runtime is lua/distilled/aws/ (protocols, endpoint rules, credentials chain, errors).
-- The client class is named after the service's sdkId (DynamoDB, Route53, EC2).
return {
  name = "aws",
  title = "AWS",
  -- unused by AWS clients (the endpoint rules pick the URL); the spec format needs one
  base_url = { default = "https://amazonaws.com" },
  auth = { kind = "none" },
  unknown_tag = "UnknownAwsError",
  parse_tag = "ParseError",
  -- member names stay the Smithy names (QueueUrl, TableName), as in Distilled
  naming = { members = "wire" },
  -- operations with event streams are emitted and fail with SdkError at call time
  allow_unsupported = { "streaming" },
  models = { skip = { "s3", "ses_events" } },
}
