#!/bin/sh
# Builds the LuaRocks release of distilled-lua into dist/rocks/<version>/:
#   <rock>-<version>-1.rockspec   from bin/distilled-lua rockspec
#   <rock>-<version>.tar.gz       the rock's source archive (upload as a GitHub release asset
#                                 of tag v<version>; the rockspec's source.url points there)
#   <rock>-<version>-1.src.rock   rockspec + archive, what `luarocks upload` sends
#   manifest                      so the directory is a LuaRocks server by itself
#
#   scripts/build_rocks.sh <version> [rock,rock,...]
#   scripts/build_rocks.sh 0.1.0 distilled,twitch     # the runtime and the Twitch client
#
# Try a build without publishing anything:
#   luarocks --lua-version 5.1 --tree /tmp/rocks --server "file://$PWD/dist/rocks/0.1.0" \
#     install distilled-twitch
# Publish (needs a luarocks.org API key and the gh CLI), after tagging v<version>:
#   gh release create v<version> dist/rocks/<version>/*.tar.gz
#   for r in dist/rocks/<version>/*.rockspec; do luarocks upload "$r" "${r%.rockspec}.src.rock"; done
#   (upload `distilled` first: the clients depend on it)
set -eu

if [ $# -lt 1 ]; then
  echo "usage: scripts/build_rocks.sh <version> [rock,rock,...]" >&2
  exit 2
fi
version="$1"
only="${2:-}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist/rocks/$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rm -rf "$out"
mkdir -p "$out"
if [ -n "$only" ]; then
  lua "$repo/bin/distilled-lua" rockspec --version "$version" --out "$work/specs" --only "$only"
else
  lua "$repo/bin/distilled-lua" rockspec --version "$version" --out "$work/specs"
fi

for list in "$work"/specs/*.files; do
  rock="$(basename "$list" .files)"
  archive_dir="$(head -n 1 "$list")"
  rockspec="$rock-$version-1.rockspec"
  # copy the listed files under <rock>-<version>/, keeping their repository paths
  mkdir -p "$work/stage/$archive_dir"
  tail -n +2 "$list" > "$work/$rock.paths"
  (cd "$repo" && tar -cf - -T "$work/$rock.paths") | (cd "$work/stage/$archive_dir" && tar -xf -)
  (cd "$work/stage" && COPYFILE_DISABLE=1 tar -czf "$out/$archive_dir.tar.gz" "$archive_dir")
  cp "$work/specs/$rockspec" "$out/$rockspec"
  # a .src.rock is a zip of the rockspec and its source archive
  (cd "$out" && zip -q -X "$rock-$version-1.src.rock" "$rockspec" "$archive_dir.tar.gz")
  rm -rf "$work/stage"
done

luarocks-admin make-manifest --lua-version 5.1 "$out" >/dev/null
echo "build_rocks: $(ls "$out"/*.rockspec | wc -l | tr -d ' ') rocks in $out"
