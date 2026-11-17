# Task 28: why posthog, whop and coinflow differ from the TypeScript operation counts

Measured on the models from `verify/dl models sync` (the current `.generated-specs` of
`../distilled`) and the committed `../distilled/packages/<pkg>/src/services/*.ts`.

| package | TS ops | model ops | Lua ops |
| --- | --- | --- | --- |
| posthog | 2622 | 2612 | 2612 |
| whop | 451 | 437 | 437 |
| coinflow | 207 | 213 | 213 |

The Lua clients contain every operation of the models (counted as `"type": "operation"`
in `models/<pkg>/*.json`), so no generator gap is involved. The difference is between
the specs: Distilled's `src/services` were generated from older spec snapshots than the
`.generated-specs` that `scripts/convert.ts` produces from the spec mirrors today. Each
operation below is in the TypeScript services and its route (`T.Http` method and uri)
is in no operation of the current model, or the other way round. Script:
`node tasks/notes/28-gapcheck.mjs <pkg> <service ...>`.

## Only in TypeScript (the route is in no current model)

| package | TS service | route | in the current model |
| --- | --- | --- | --- |
| posthog | loops | `PATCH /api/projects/{project_id}/loops/{id}/` | not in model |
| posthog | loops | `PUT /api/projects/{project_id}/loops/{id}/skill_bundles/` | not in model |
| posthog | loops | `POST /api/projects/{project_id}/loops/` | not in model |
| posthog | loops | `POST /api/projects/{project_id}/loops/{id}/preview/` | not in model |
| posthog | loops | `POST /api/projects/{project_id}/loops/{id}/run/` | not in model |
| posthog | loops | `GET /api/projects/{project_id}/loops/{id}/` | not in model |
| posthog | loops | `GET /api/projects/{project_id}/loops/{id}/runs/` | not in model |
| posthog | loops | `GET /api/projects/{project_id}/loops/` | not in model |
| posthog | loops | `DELETE /api/projects/{project_id}/loops/{id}/` | not in model |
| posthog | loops | `POST /api/projects/{project_id}/loops/{id}/trigger/` | not in model |
| whop | companies | `POST /companies/{parent_company_id}/api_keys` | not in model |
| whop | companies | `POST /companies` | not in model |
| whop | companies | `GET /companies/{id}` | not in model |
| whop | companies | `GET /companies` | not in model |
| whop | companies | `PATCH /companies/{id}` | not in model |
| whop | entries | `POST /entries/{id}/approve` | not in model |
| whop | entries | `POST /entries/{id}/deny` | not in model |
| whop | entries | `GET /entries/{id}` | not in model |
| whop | entries | `GET /entries` | not in model |
| whop | recommended_actions | `GET /recommended_actions/{id}` | not in model |
| whop | recommended_actions | `GET /recommended_actions/{id}/executions` | not in model |
| whop | recommended_actions | `GET /recommended_actions` | not in model |
| whop | recommended_actions | `POST /recommended_actions/{id}` | not in model |
| whop | ad_reports | `GET /ad_reports` | not in model |
| coinflow | merchant_accounts | `POST /merchant/accounts/subsidiaries` | not in model |
| coinflow | merchant_accounts | `GET /merchant/accounts/subsidiaries` | not in model |
| coinflow | merchant_accounts | `DELETE /merchant/accounts/subsidiaries/{subsidiaryId}` | not in model |

PostHog's pinned mirror (`spec-mirror-posthog` 39619b6, 2026-11-08) has no `/loops/`
path at all; `loops.ts` was generated before that endpoint left the published document.
Whop's two documents (`api-v1-native.json`, `api-v1-stable.json`, mirror 8a5483a) have
no `/companies`, `/entries`, `/recommended_actions` or `/ad_reports` path (the current
document has `/waitlist_entries` and `/accounts/{id}/form_company` instead).
Coinflow's mirror (9aa311f, 2026-11-14) renamed the subsidiaries API.

## Only in Lua (in the current model, not in the TypeScript services)

coinflow `merchant_accounts`: `create_embedded_account`, `create_embedded_group`,
`create_withdrawal`, `get_embedded_accounts`, `get_embedded_group_accounts`,
`get_embedded_groups`, `get_withdrawal_options`, `remove_embedded_account`,
`search_embedded_accounts` (9 operations; with the 3 subsidiary operations TS has and
the model does not: 213 - 207 = 6).

Nothing to fix: regenerating Distilled's services from the same models would give the
Lua counts.
