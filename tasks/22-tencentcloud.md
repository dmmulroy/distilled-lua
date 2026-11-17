# Task 22: Tencent Cloud (263 models, ~15,400 operations)

Read `tasks/10-parity-overview.md`, `STATUS.md` and `verify/features/crypto.md` (SHA-256,
HMAC from task 14) first. Models: `verify/dl models sync tencentcloud`. Smoke today:
0/263 ("no smithy.api#http trait": Tencent is an RPC-style protocol, every action a POST
to `<service>.tencentcloudapi.com` with `X-TC-Action`, `X-TC-Version`, `X-TC-Region`,
`X-TC-Timestamp` and TC3-HMAC-SHA256 `Authorization`). Glue:
`../distilled/packages/tencentcloud/src/` (protocol.ts, credentials, errors, retry).

## Files you own

```text
lua/distilled/tencentcloud/*.lua or protocol/tencentcloud.lua (new), incl. the TC3 signer
lua/distilled/gen/*    ONLY RPC-model support without http traits (prefer new file + hooks)
providers/tencentcloud.lua, clients/tencentcloud/ (generated, committed)
spec/tencentcloud_*_spec.lua, verify/features/tencentcloud.md
STATUS.md (section "22 tencentcloud")
```

## Requirements

1. TC3-HMAC-SHA256 signing byte-exact with Distilled (vectors from its tests and from
   Node), the `{ Response: { Error: { Code, Message }, RequestId } }` envelope and error
   code -> class mapping, credentials (env, profile if Distilled has it), region,
   endpoints, pagination (Offset/Limit, TotalCount) as Distilled does.
2. All models generate, load in three runtimes, build every request (`gen-diff`);
   coordinate with task 18 on output size.
3. Conformance against Distilled's TS for a sample of operations.
