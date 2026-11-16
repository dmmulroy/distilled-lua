#!/bin/sh
# Smoke-generate one model with a dummy provider spec, using THIS checkout's generator.
# usage: sh tasks/notes/smoke-run1.sh <pkg>/<model>   (output under /tmp/smoke-$USER-<worktree>)
pm=$1; p=${pm%%/*}; m=${pm#*/}
name=$(printf '%s_%s' "$p" "$m" | tr 'A-Z-.' 'a-z__')
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=$(cd "$ROOT/.." && pwd)
W=/tmp/smoke-$(basename "$ROOT"); mkdir -p $W/prov $W/out
f=$D/distilled/packages/$p/.generated-specs/$m.json
[ -f $f ] || f=$D/distilled/packages/$p/.generated-graphql/$m.json
cat > $W/prov/$name.lua <<P
return { name = "$name", base_url = "https://example.invalid", auth = { kind = "bearer", from = "api_key", env = "X_KEY" }, unknown_tag = "UnknownErr", parse_tag = "ParseErr", naming = { members = "wire" } }
P
start=$(date +%s)
if luajit $ROOT/bin/distilled-lua generate --model $f --provider $W/prov/$name.lua --out $W/out/$name --quiet >$W/log_$name.txt 2>&1; then
  echo "OK $pm $(( $(date +%s)-start ))s"
else
  echo "FAIL $pm $(head -c 300 $W/log_$name.txt | tr '\n' ' ')"
fi
