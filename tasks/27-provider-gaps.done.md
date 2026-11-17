# Task 27 (provider-gaps): done

## What was built

1. **`models.override` per-model specs** (`lua/distilled/gen/provider.lua`).
   - An override may carry `auth`, `options`, `headers`, `require_one_of`,
     `public_operations`, `oauth`, `user_agent`, `error_envelope`, `unknown_fields`,
     `transform_response`, `empty_json_body` and `glue` (`provider.MODEL_SPEC_KEYS`),
     besides `title` and `base_url`.
   - Each key replaces the package's key for that model, and `false` removes it.
     `base_url` merges field by field, and a `false` field is removed.
   - The merged raw spec is validated whole by `provider.validate` (strict, problems
     prefixed `provider spec models.override.<m>:`). This happens before the runtime
     data is computed, as task 13 asked. `for_model` returns that spec.
   - A title/classic-base_url-only override keeps task 10's path, so no existing output
     changed.
   - The per-model packages use it and mirror their TS credentials/protocol pairs:
     - **clerk**: platform.
     - **convex**: deployment and functions.
     - **digitalocean**: functions (basic auth, `api_host`).
     - **exa**: team_management.
     - **onepassword**: events, oauth, users (OAuth client credentials), partnership.
     - **mailchimp**: transactional, with `glue/mailchimp_transactional.lua` (the `key` body
       member and Mandrill failures). Marketing now also has MailchimpApiError and the
       problem's type/title/instance fields.
     - **fly_io**: mpg; sprites, with `glue/fly_io_sprites.lua` (organization discovery,
       token mint and cache, FlyV1 for the mint op, exec frames, NDJSON,
       SpritesNotEnabled).
     - **e2b**: envd, filesystem and process (EnvdProtocol headers and host,
       `glue/e2b_envd.lua`, empty JSON bodies), and volume_content.
2. **Slack** (`providers/slack.lua`, `providers/glue/slack.lua`), 36 models.
   - The token comes from SLACK_BOT_TOKEN, else SLACK_TOKEN. The oauth and openid models
     make it optional, so no Authorization header is sent without one.
   - `serializeForWire`: a query list is comma-joined. Form fields are comma-joined
     (scalar lists) or JSON (anything else), never bracketed. request.build already
     encodes form bodies; the glue reads the input plan through the new
     `transform_input(input, op, settings, service)`.
   - `ok:false` with a 2xx status is a failure (classify_success). It is then classified
     by slug:
     - SlackRateLimited (429 or `rate_limited`/`ratelimited`, throttling, Retry-After);
     - the auth slugs become Unauthorized;
     - the server slugs become InternalServerError, ServiceUnavailable or GatewayTimeout;
     - any other slug is a SlackError with the slug as `code`, plus `needed`, `provided`
       and `messages`;
     - with no slug: the status classes, then SlackHttpError (body cut to 2,000).
   - The message is response_metadata.messages[1], else errors[1], else the slug, else
     the text, else `HTTP n`.
   - Token kinds: credentials.ts says the header is the same for every kind, so there is
     no option, and the spec comment documents the kinds.
3. **Scaleway** (`providers/scaleway.lua`, `providers/glue/scaleway.lua`), 98 models.
   - X-Auth-Token comes from SCW_SECRET_KEY.
   - A missing `{region}` or `{zone}` label (absent, null or "") is filled from the
     region/zone options (SCW_DEFAULT_REGION / SCW_DEFAULT_ZONE, defaults fr-par /
     fr-par-1).
   - SCW_API_URL moves only the api.scaleway.com operations. api.scaleway.ai operations
     also get `Authorization: Bearer`.
   - Answers: nulls are stripped and X-Total-Count is folded into `total_count`. This
     uses the new `transform_response(body, op, { status, headers })`.
   - Failures map by `body.type` to every errors.ts class, including the legacy
     `unknown_resource` and `invalid_request_error`. The message is failureMessage. The
     fallback is UnknownScalewayError (ServerError) with `code = type`.
   - Raw downloads send `dl=1` (rest.lua, `op.raw_download`).
   - Page lists use the new `pagination.modes = { page = "total_count" }` spec key and the
     `distilled.paginate` mode `total_count` (paginateByTotalCount).
4. **Questrade** (`providers/questrade.lua`, `providers/glue/questrade.lua`).
   - Credentials are either an access token with an API server, or a refresh token
     redeemed with `GET <login origin>/oauth2/token?grant_type=refresh_token&refresh_token=…`.
   - It follows the rotation: the access token is reused until 60 s before expiry, then
     the returned refresh token is redeemed. The cache key is the SHA-256 of the token.
   - The API server is normalized.
   - Errors never quote the URL or the refused body. A transport error has the token
     replaced as a second defence.
   - **No transport change was needed.** popen_curl and exec_curl already put the URL in
     the curl config (a 0600 temp file or stdin), never in argv, and scrub the query from
     their messages. Task 13's premise was wrong. This is proven by spec (argv and the
     shell command checked for both transports) and by `dl canary`, which has a negative
     control.
5. Specs:
   - `spec/provider_models_spec.lua`: the override validation, `pagination.modes`, and
     every per-model client over the scripted transport.
   - `spec/slack_client_spec.lua`, `spec/scaleway_client_spec.lua` and
     `spec/questrade_client_spec.lua`.
   - `spec/provider_spec.lua`: NAMES.
6. `docs/generating.md` section 4: per-model credentials, `pagination.modes`, the new glue
   signatures and glue-side credential exchanges. `STATUS.md` section 27.

## After the last merge (task 25, at d478d13)

`verify/dl gen-all` for the 11 packages: no diff. `verify/dl doctor`: ok. All 11 `gen-diff`s:
ok. `verify/dl test`: lua 1847 passed, 20 pending; luajit 1847 passed, 20 pending; rex 1834
passed, 26 pending. `verify/dl fmt --check` now fails only on `spec/golden/s3/presign.lua`
and `spec/golden/s3/conform.lua` (stylua prefers single quotes). Those files are task 25's
and are identical on main, so I left them alone.

## Commands run (after `git merge origin/main` at 6b42161)

```text
$ verify/dl models sync
models sync: 2256 models
$ verify/dl gen-all clerk convex digitalocean e2b exa fly_io mailchimp onepassword slack scaleway questrade
gen-all: 11 packages; models: 171 ok, 0 failed, 0 skipped      (no diff to the committed clients)
$ verify/dl doctor
doctor: ok
$ verify/dl fmt --check            # exit 0
$ for p in clerk convex digitalocean e2b exa fly_io mailchimp onepassword slack scaleway questrade; do verify/dl gen-diff $p; done
ok gen-check rex: 2 services, 1380 shapes, 1715 refs resolved, 320/320 ops built, ...   gen-diff clerk: ok
ok gen-check rex: 3 services, 378 shapes, 449 refs resolved, 79/79 ops built, ...       gen-diff convex: ok
ok gen-check rex: 2 services, 4583 shapes, 5691 refs resolved, 924/924 ops built, ...   gen-diff digitalocean: ok
ok gen-check rex: 16 services, 351 shapes, 402 refs resolved, 97/97 ops built, ...      gen-diff e2b: ok
ok gen-check rex: 2 services, 661 shapes, 776 refs resolved, 72/72 ops built, ...       gen-diff exa: ok
ok gen-check rex: 3 services, 635 shapes, 723 refs resolved, 174/174 ops built, ...     gen-diff fly-io: ok
ok gen-check rex: 2 services, 3954 shapes, 3954 refs resolved, 393/393 ops built, ...   gen-diff mailchimp: ok
ok gen-check rex: 5 services, 202 shapes, 245 refs resolved, 33/33 ops built, ...       gen-diff onepassword: ok
ok gen-check rex: 36 services, 1405 shapes, 1405 refs resolved, 355/355 ops built, ...  gen-diff slack: ok
ok gen-check rex: 98 services, 7007 shapes, 8645 refs resolved, 1580/1580 ops built, ... gen-diff scaleway: ok
ok gen-check rex: 141 shapes, 183 refs resolved, 25/25 ops built, ...                   gen-diff questrade: ok
(each gen-diff also: lua and luajit write identical files, diff clean, stylua --check,
 gen-check under Lua 5.5 and luajit)
$ verify/dl test
  lua: ok 1671 passed, 5 pending [Lua 5.5]
  luajit: ok 1671 passed, 5 pending [luajit]
  rex: ok 1658 passed, 11 pending [rex]
$ verify/dl test --http            (before the last merge)
  lua: ok 1710 passed   luajit: FAIL 1 failed, 1709 passed   rex: ok 1677 passed, 6 pending
$ verify/dl test --http --runtime luajit   (rerun 3 times)
  luajit: ok 1710 passed   (each time)
$ verify/dl canary tasks/notes/27-questrade-canary.lua
ok   canary lua: key absent from stdout, stderr, trace (3 lines), 11 curl ps entries; reached the server
ok   canary luajit: key absent from stdout, stderr, trace (3 lines), 11 curl ps entries; reached the server
ok   canary rex: key absent from stdout, stderr, trace (3 lines), 10 curl ps entries; reached the server
$ (negative control: clients/questrade/glue.lua edited to put the token in the 400 message, then restored)
FAIL canary lua: key in stdout.txt (lines 4 5 )
FAIL canary lua: key in the trace file (lines 3 )
$ verify/dl parity   (not committed: parity.md is task 26's)
| clerk | 320 | 320 | 2/2 | 0 | yes |        | convex | 79 | 79 | 3/3 | 0 | yes |
| digitalocean | 924 | 924 | 2/2 | 0 | yes | | e2b | 97 | 97 | 16/16 | 0 | yes |
| exa | 72 | 72 | 2/2 | 0 | yes |           | fly-io | 174 | 174 | 3/3 | 0 | yes |
| mailchimp | 393 | 393 | 2/2 | 0 | yes |    | onepassword | 33 | 33 | 5/5 | 0 | yes |
| questrade | 25 | 25 | 1/1 | 0 | yes |      | scaleway | 1580 | 1580 | 98/98 | 0 | yes |
| slack | 355 | 355 | 36/36 | 0 | yes |
```

Error, empty and retry paths are exercised by spec. They include:

- ConfigErrors for missing options and refused or empty token exchanges, with the secret
  absent from the message.
- The Slack 429 retried by the default policy, then a success.
- Retryable classes (TransientStateError, the server slugs).
- Empty-page, empty-cursor and no-total pagination stops.
- Non-JSON failure bodies.

Client sizes: scaleway 8.4M, digitalocean 3.8M, mailchimp 3.4M, slack 2.2M, clerk 1.2M,
fly_io 728K (including task 16's graphql), e2b 500K, exa 452K, convex 328K, onepassword
216K, questrade 136K.

## Files touched outside my list

- `lua/distilled/paginate.lua`: the `total_count` strategy, added without changing the
  existing modes.
- `lua/distilled/gen/ops.lua`: one line maps the trait mode through
  `pagination.modes`.
- `spec/provider_spec.lua`: NAMES (spec files are allowed).
- `tasks/notes/27-questrade-canary.lua`: the canary script.

## Skipped or unverified, and why

- No live API calls, per the rules. The behaviour was checked against each package's TS
  by reading it, and by fixture exchanges over the scripted transport.
- The `--http` suite had one luajit failure in its first run that did not come back in
  three reruns. My changes do not touch transports or the HTTP specs, and I did not
  capture the failing spec's name.
- Slack and Scaleway run their glue `classify_error` before an operation's typed
  matchers; Distilled runs the matchers first. Neither package generates per-operation
  error classes, so today the result is the same.
- Scaleway: a success body that parses as JSON is JSON whatever its Content-Type.
  Distilled returns text unless the type says JSON (Instance user data is `text/plain`).
- fly_io: MachineIdentity (dropping auth inside a Machine) is not mirrored. Minted
  Sprites tokens are cached for the life of the process, as in Distilled.
- Questrade: there is no `onRefresh` hook, so rotated refresh tokens stay in memory, as
  with Distilled's CredentialsFromEnv. It needs a function-typed provider option
  (proposal in STATUS 27).

## Open problems

- Task 23 owns `providers/e2b.lua` and `clients/e2b/` too. I added the REST-level envd and
  volume overrides, so a merge conflict is likely there. The Connect streaming parts are
  task 23's.
- Stale docs I do not own (see STATUS 27):
  - `provider_ext.lua`'s HOOKS doc strings;
  - `docs/providers-survey.md`'s slack, scaleway and questrade rows;
  - `docs/interfaces.md` (the glue signatures, `pagination.modes`, `MODEL_SPEC_KEYS`,
    `raw_download`).
