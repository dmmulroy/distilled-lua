# distilled-lua

A standalone Lua library and generator that turns Distilled's patched Smithy models into
Lua API clients. Pure Lua 5.1 baseline: runs on PUC Lua 5.1 to 5.5, LuaJIT and gopher-lua
(Rex), with no dependencies.

Status: in progress. The design is in `../distilled-lua-plan.md`, module contracts in
`docs/interfaces.md`, agent rules in `AGENTS.md`, progress in `STATUS.md`.

```sh
verify/dl doctor        # check the toolchain
verify/dl test          # run specs under lua, luajit and rex
verify/dl help          # everything else
```
