# Task 28: Coinbase, Polymarket, and the remaining parity gaps in REST packages

Read `tasks/10-parity-overview.md`, `STATUS.md` (13, 14, 24, 26, 27) and
`verify/features/parity.md` first. Public-key crypto and JWT/JWS exist
(`lua/distilled/crypto/`, task 24).

## Files you own

```text
providers/coinbase.lua, polymarket.lua (+ providers/glue/ modules for them)
lua/distilled/protocol/rest.lua   ONLY signing hooks these two need (prefer glue modules)
clients/coinbase/, clients/polymarket/ (generated, committed)
clients/posthog/, clients/whop/   regenerate if you fix their gaps
lua/distilled/gen/*               small fixes for the posthog/whop gaps (with fixture specs)
spec/*_spec.lua (new cases)
STATUS.md (section "28 signed-rest")
```

## Requirements

1. Coinbase: its JWT auth (ES256 / Ed25519 per key type) exactly as
   `../distilled/packages/coinbase/src/protocol.ts`; nonce/uuid from host.random.
2. Polymarket (7 models): L1 (EIP-712 secp256k1) and L2 (HMAC) auth headers as
   `../distilled/packages/polymarket/src/protocol.ts`, byte-exact against Node vectors.
3. posthog is 10 operations short of TS (2,612 / 2,622), whop 14 (437 / 451), coinflow 6
   over (213 / 207): find why per operation and fix or explain.
4. `verify/dl gen-diff` for each package touched; push `task-28` after each step.
