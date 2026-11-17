#!/bin/sh
# Large-model report (task 18): for each <pkg>/<model>, generate with a dummy provider spec
# (as tasks/notes/smoke-run1.sh) using the generator BEFORE task 18 (git ref $DL_BEFORE_REF)
# and the current one, then measure output size, generation time and memory (lua, luajit)
# and load time and memory (lua, luajit, rex) of both outputs.
#
#   sh verify/lib/big_models.sh infisical/infisical stripe/stripe ...
#   sh verify/lib/big_models.sh syn:2000:8   (a synthetic model, verify/lib/big_synth.lua:
#                                            2000 operations, 8 members per shape)
#   DL_BEFORE_REF=<ref> (default c09d560, main when task 18 started)
#   DL_BIG_RUNTIMES="lua luajit rex"   DL_BIG_OUT=<dir> (default /tmp/dl-big-models)
#
# A model the current generator refuses for a reason other tasks own (AWS errors, Azure
# apiVersion, Cloudflare pagination) goes through verify/lib/bench_sanitize.mjs first; the
# report says how many operations that dropped. Prints one block per model; the raw
# measurements are in $DL_BIG_OUT/<name>/report.txt.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=$(cd "$ROOT/.." && pwd)
BEFORE_REF=${DL_BEFORE_REF:-c09d560}
RUNTIMES=${DL_BIG_RUNTIMES:-lua luajit rex}
OUT=${DL_BIG_OUT:-/tmp/dl-big-models}
mkdir -p "$OUT"

# the generator before task 18, as files (no worktree, no checkout)
BEFORE="$OUT/before-$BEFORE_REF"
if [ ! -f "$BEFORE/bin/distilled-lua" ]; then
  mkdir -p "$BEFORE"
  (cd "$ROOT" && git archive "$BEFORE_REF" lua bin verify/lib/gen_input.lua) | tar -x -C "$BEFORE"
fi

# time_rss <log> <cmd...>: runs cmd, appends "<real s> <max rss bytes>" to stdout
time_rss() {
  log=$1
  shift
  /usr/bin/time -l "$@" >"$log" 2>"$log.time"
  code=$?
  real=$(awk '/ real /{print $1}' "$log.time")
  rss=$(awk '/maximum resident set size/{print $1}' "$log.time")
  echo "$real $rss $code"
}

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

for pm in "$@"; do
  p=${pm%%/*}
  m=${pm#*/}
  name=$(printf '%s_%s' "$p" "$m" | tr 'A-Z-.' 'a-z__')
  W="$OUT/$name"
  rm -rf "$W"
  mkdir -p "$W"
  R="$W/report.txt"
  cat >"$W/provider.lua" <<P
return { name = "$name", base_url = "https://example.invalid", auth = { kind = "bearer", from = "api_key", env = "X_KEY" }, unknown_tag = "UnknownErr", parse_tag = "ParseErr", naming = { members = "wire" } }
P
  model="$ROOT/models/$p/$m.json"
  case $pm in
    syn:*)
      ops=$(echo "$pm" | cut -d: -f2)
      members=$(echo "$pm" | cut -d: -f3)
      name="syn_${ops}_${members:-4}"
      W="$OUT/$name"
      R="$W/report.txt"
      rm -rf "$W"
      mkdir -p "$W"
      model="$W/synthetic.json"
      (cd "$ROOT" && luajit -e "package.path='lua/?.lua;lua/?/init.lua;./?.lua;'..package.path
        io.write(require('verify.lib.big_synth').text({ ops = $ops, members = ${members:-4} }))") >"$model"
      sed "s/name = \"[a-z0-9_]*\"/name = \"$name\"/" >"$W/provider.lua" <<P
return { name = "x", base_url = "https://example.invalid", auth = { kind = "bearer", from = "api_key", env = "X_KEY" }, unknown_tag = "UnknownErr", parse_tag = "ParseErr", naming = { members = "wire" } }
P
      ;;
  esac
  [ -f "$model" ] || { echo "$pm: no model $model (verify/dl models sync $p)"; continue; }
  cp "$model" "$W/model.json"
  note="as is"
  i=0
  while :; do
    if luajit "$ROOT/bin/distilled-lua" generate --model "$W/model.json" --provider "$W/provider.lua" \
      --out "$W/probe" --quiet >"$W/probe.log" 2>&1; then
      break
    fi
    i=$((i + 1))
    if [ $i -gt 4 ]; then
      note="does not generate: $(head -c 200 "$W/probe.log")"
      break
    fi
    if [ $i -eq 1 ]; then
      # first the generic fixes only: they may be all it takes
      changes=$(node "$ROOT/verify/lib/bench_sanitize.mjs" "$model" "$W/model.json")
    else
      changes=$(node "$ROOT/verify/lib/bench_sanitize.mjs" "$W/model.json" "$W/model.json" "$W/probe.log")
    fi
    note="sanitized: $changes"
  done
  rm -rf "$W/probe"
  total_ops=$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(Object.values(m.shapes).filter(s=>s.type=="operation").length)' "$model")
  {
    echo "## $pm ($(mb "$(wc -c <"$model")") MB model, $total_ops operations; $note)"
    for which in before after; do
      if [ "$which" = before ]; then G="$BEFORE"; else G="$ROOT"; fi
      for rt in luajit lua; do
        res=$(time_rss "$W/gen_${which}_$rt.log" "$rt" "$G/bin/distilled-lua" generate --model "$W/model.json" \
          --provider "$W/provider.lua" --out "$W/$which/$name" --quiet)
        set -- $res
        echo "$which generate $rt: $1 s, $(mb "$2") MB rss, exit $3"
      done
      dir="$W/$which/$name"
      if [ -f "$dir/service.lua" ]; then
        svc=$(wc -c <"$dir/service.lua" | tr -d ' ')
        chunks=0
        chunk_bytes=0
        if [ -d "$dir/service" ]; then
          chunks=$(ls "$dir/service" | wc -l | tr -d ' ')
          chunk_bytes=$(cat "$dir/service"/*.lua | wc -c | tr -d ' ')
        fi
        types=$(wc -c <"$dir/types.lua" | tr -d ' ')
        readme=$(wc -c <"$dir/README.md" | tr -d ' ')
        echo "$which output: service.lua $(mb "$svc") MB + service/ $chunks files $(mb "$chunk_bytes") MB; types.lua $(mb "$types") MB; README $(mb "$readme") MB"
        for rt in $RUNTIMES; do
          for stop in require call; do
            if [ "$rt" = rex ]; then
              res=$(time_rss "$W/load_${which}_${rt}_$stop.log" rex do "$ROOT/verify/lib/load_bench.lua" \
                "root=$ROOT" "dir=$W/$which" "module=$name" "stop=$stop")
            else
              res=$(time_rss "$W/load_${which}_${rt}_$stop.log" "$rt" "$ROOT/verify/lib/load_bench.lua" \
                "$ROOT" "$W/$which" "$name" - "$stop")
            fi
            set -- $res
            line=$(grep -v '^"' "$W/load_${which}_${rt}_$stop.log" | tail -n 1 | cut -c1-200)
            [ "$3" = 0 ] || line="FAIL $(cat "$W/load_${which}_${rt}_$stop.log" "$W/load_${which}_${rt}_$stop.log.time" | grep -i 'error\|constants\|refused' | head -n 2 | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-200)"
            echo "$which load $rt $stop: process $1 s, $(mb "$2") MB rss | $line"
          done
        done
      fi
    done
    echo
  } | tee "$R"
done
