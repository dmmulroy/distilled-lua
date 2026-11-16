# Pagination (`distilled.paginate`)

## Sub-features

- `paginate.pages(call, input, trait, opts)` and `paginate.items(...)`: iterator objects.
  Callable (`for x in it do`), stop at the first failure (`it.err`), `it:collect([limit])
  -> list | nil, err` (limit stops fetching once enough values are collected),
  `it:close()`. Fields: `it.done`, `it.stop` (why it stopped), `it.pages`, `it.count`.
- Modes and stop conditions (`pagination.ts`), `it.stop` in brackets:
  - `token` (default): token missing, null or `""` [`no_token`];
  - `cursor`: terminal cursor [`no_token`], a cursor already requested [`repeated_cursor`];
  - `page`: no token [`no_token`], an empty or null items page [`empty_page`]; only an
    advancing page number is taken;
  - `relay`: `hasNextPage` false or absent [`no_next_page`], terminal cursor, empty page
    [`empty_page`], stuck cursor [`stuck_cursor`];
  - `link`: no `rel="next"` link [`no_next_link`], repeated token [`repeated_token`];
  - `keyset`: empty page, no key, key not advancing [`key_not_advancing`], short page
    [`short_page`];
  - `single` [`single`]. Also `limit`, `closed`, `error`.
- Items by dotted path that crosses arrays (`edges.node`), or the page itself when it is a
  bare array. `get_path`, `get_items`, `next_link`, `query_param` are exported.
- **Link headers without a global:** the page call returns `page, nil, meta`, and
  `meta.headers` carries the response headers (the REST protocol returns them as a third
  value from every call).
- Tracing: one `distilled.pagination` span per traversal (mode, kind, operation, pages,
  items, stop), parent of each page's operation span. Between pulls it is off the
  tracer's stack, so the loop body's own calls are not parented to it and an abandoned
  iterator does not capture later spans.

## How a user reaches it

```lua
local projects, err = neon:list_projects_items{}:collect(50)
local it = neon:list_projects_items{}
for p in it do print(p.name) end
if it.err then return nil, it.err end
for page in neon:list_projects_pages{ limit = 10 } do ... end
```

## Driving it with `dl`

- `verify/dl test paginate_spec`: the scenarios of `pagination.test.ts` (cursor, nextLink,
  keyset), the Link-header cases of `protocol-rest.test.ts` through the REST protocol,
  every stop condition by mode (asserted on `it.stop` and the request list), iterator
  behaviour (limit, failure, close, empty), and the traversal span.
- `verify/dl trace examples/fake_service.lua` shows a two-page traversal.

## Gotchas

- Trait paths are user names (after key mapping); the generator must emit them so.
- The traversal span touches the tracer's private `_stack` (two helpers in
  `paginate.lua`); see STATUS.md 04 for the proposed tracer API.
- Lua cannot see a `break` out of `for`; call `it:close()` when abandoning a traversal
  with tracing on, or the traversal span stays unfinished (it is still not on the stack).
- An unmarked empty table at an items path counts as an empty list (hand-built data);
  decoded JSON is always marked.
