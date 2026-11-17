Event stream codec test vectors copied unchanged from aws-sdk-go-v2
(`aws/protocol/eventstream/testdata/`, https://github.com/aws/aws-sdk-go-v2, Apache-2.0).
`encoded/` holds the bytes, `decoded/` the expected message (positive) or the error
(negative). verify/lib/aws_eventstream_conform.mjs folds them into ../conform.lua.
