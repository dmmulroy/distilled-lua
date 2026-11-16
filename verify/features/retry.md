# Retry, budget and deadline (`distilled.retry`)

## Sub-features

- Policies as data: `{ when, max_retries, base_ms, throttling_base_ms, factor, cap_ms,
  full_jitter, jitter_ms, min_throttle_ms, server_hint, budget, long_poll }`. Presets with
  Distilled's numbers: `retry.DEFAULT` (transient errors, 2 retries, full jitter from 50 ms
  or 1 s for throttling, 20 s cap, server hints, budget), `retry.THROTTLING` and
  `retry.TRANSIENT` (1 s base, factor 2, 5 s cap, 50 ms jitter, hints, no limit, no
  budget), `retry.NONE`.
- `retry.policy_for(spec, op.retry)`: the client's `retry` option (preset, preset name, or
  fields over the default) and the operation's `distilled.retry#policy` numbers
  (`max_attempts, base_ms, throttling_base_ms, cap_ms, factor, long_poll`), which apply only
  when the client set no policy.
- `retry.run(fn, { policy, host, tracer, span, deadline_s, server_hint_cap_s })`: the call
  runs once with no bookkeeping; the policy is read only after a failure.
- Server hints: `err.retry_after` (seconds, from `Retry-After` / `RateLimit`) is a minimum
  wait; over the cap (60 s, `server_hint_cap_s`, or `DISTILLED_SERVER_RETRY_HINT_CAP_MS`
  through `host.getenv`) it stops retrying. Bounded hints (`x-amz-retry-after`,
  `x-distilled-retry-after`, ms) clamp to `[t, t + 5 s]` and apply only to the retry after
  the response that carried them.
- Budget: `retry.new_budget{ initial = 100, max = 500, transient_cost = 14,
  throttling_cost = 5 }`, a bucket per host; successes add a token, a successful retry is
  refunded; `long_poll` waits the delay before failing on an empty bucket.
  `retry.default_budget` is shared by every client that does not pass `budget`.
- Deadline: `deadline_s` covers the whole call with its sleeps; a sleep that would pass it
  returns the last error instead; each try gets the time left as `request.timeout`.
- Parsers: `parse_retry_after(headers, now)` (delay-seconds, IMF-fixdate, RFC 850,
  asctime), `parse_ratelimit`, `parse_server_hint`, `parse_for_status`, `bounded_hint_ms`,
  `host_of`.

## How a user reaches it

```lua
local neon = Neon.new{ api_key = key, transport = t, retry = { max_retries = 5 } }
local patient = neon:with{ retry = "transient", deadline_s = 25 }
local quick = neon:with{ retry = "none" }
local shared = Neon.new{ api_key = key, budget = retry.new_budget{ initial = 50 } }
```

## Driving it with `dl`

- `verify/dl test retry_spec` (all three runtimes): the cases of `retry.test.ts` and
  `retry-after.test.ts` run through a real client over the scripted transport, with
  random pinned as Distilled pins `Math.random`. Waits are read from the fake host's
  `sleeps`; trace assertions check `distilled.attempts`, `distilled.retry.errors`,
  `distilled.retry.delay_ms`, `distilled.retry.stopped`, the debug `distilled.attempt`
  and `distilled.retry.backoff` spans.
- `verify/dl trace examples/fake_service.lua --level debug` shows a 429 (Retry-After 1)
  and a 503 retried, with the backoff spans.

## Gotchas

- `distilled.retry.stopped` (`"budget" | "deadline" | "hint_over_cap"`) is ours; the other
  operation-span attributes are `telemetry.ts`'s names (`distilled.attempts`, not
  `distilled.retry.attempts`).
- The budget counts successes itself; Distilled keeps one success counter per process
  that every budget reads. Same numbers when one budget is in use.
- A try that never sent a request (credentials, InvalidInput) has no host and is not
  budgeted.
- A `when` that raises becomes `SdkError` (`compat.pcall`, never plain pcall).
- The default `host.sleep` is a busy wait (pure Lua has no sleep): hosts should pass one.
- THROTTLING / TRANSIENT have no retry limit: give them a deadline.
