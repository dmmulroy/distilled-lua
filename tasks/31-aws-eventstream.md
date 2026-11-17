# Task 31: AWS event streams (output streams, then bidirectional)

Read `AGENTS.md`, `STATUS.md` (14, 17, 25, 29), `verify/features/aws.md` and
`tasks/29-streaming-core.md` (the reader/Stream contract; task 29 builds it in parallel:
code against it, `git merge main` once it lands). About 30 AWS operations use event
streams and are refused today: ~20 output-only (bedrock-runtime
InvokeModelWithResponseStream / ConverseStream, lambda InvokeWithResponseStream, kinesis
SubscribeToShard, s3 SelectObjectContent, ...), 10 bidirectional (transcribe-streaming,
lex StartConversation, bedrock InvokeModelWithBidirectionalStream, polly, qbusiness Chat,
sagemaker-runtime-http2, connecthealth). Distilled: `aws/src/protocols/*` (eventStreamWith,
isOutputEventStream), `s3/src/eventstream/`, `core/src/protocol-http.ts`.

## Files you own

```text
lua/distilled/crypto/crc32.lua (new)          CRC-32 (IEEE), pure Lua, vectors
lua/distilled/aws/eventstream.lua (new)       message codec: prelude, headers, payload, CRCs
lua/distilled/stream/aws_eventstream.lua (new) framing on a reader -> union events
lua/distilled/aws/*, lua/distilled/s3/*       ONLY the event-stream paths
lua/distilled/gen/aws*.lua                    op.stream for event-stream outputs/inputs
clients/aws/ (affected services), clients/s3/ (regenerate)
spec/aws_eventstream_spec.lua; verify/features/aws.md (event streams section)
STATUS.md (section "31 aws-eventstream")
```

## Requirements

1. Codec byte-exact with Distilled's (and AWS's published examples): headers of every
   type, prelude and message CRCs checked (a bad CRC is a ParseError), `:message-type`
   event / exception / error mapped to union members and modeled error classes.
2. Output streams: `client:<op>_stream(input)` yields typed events as they arrive; the
   initial-response / output members that are not the stream come back on the Stream
   object (`stream.output`). Incremental delivery proven against `dl serve`.
3. Bidirectional streams need full duplex. Find what works through curl (HTTP/2,
   `-T -` / `--data-binary @-` with stdin kept open) and each host: Rex
   `rex.exec.start{ stdin = true }` + `h:write`; popen is one-way, so stock Lua may not
   be able to. Implement event signing (SigV4 chunk signatures with the prior signature,
   `:chunk-signature`, `:date`) and an input side (`stream:send(event)`,
   `stream:close_input()`) where the host can do it; where it cannot, the operation
   fails with a clear SdkError naming the host limit. Say exactly what was proven.
4. Conformance vs Distilled's TS for encoded/decoded messages and requests.
Push `task-31` after every meaningful step.
