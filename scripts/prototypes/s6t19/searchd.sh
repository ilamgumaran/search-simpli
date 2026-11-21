#!/usr/bin/env bash
# S6-T19 ruling 1: `searchd` ReleaseSmall from a fresh `git archive` of each commit, each with its own local and
# global Zig caches, compared with cmp.
#   scripts/prototypes/s6t19/searchd.sh MAIN HEAD SCRATCH
# Zig on PATH. Never removes anything.
set -uo pipefail
main="$1"; head="$2"; scratch="$3"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
for c in "$main" "$head"; do
  dir="$scratch/searchd-$c"
  if [ -e "$dir" ]; then echo "searchd.sh: $dir exists" >&2; exit 2; fi
  mkdir -p "$dir" && git -C "$repo" archive "$c" | tar -x -C "$dir"
  (cd "$dir/zig" && zig build -Doptimize=ReleaseSmall --prefix "$dir/out" --cache-dir "$dir/.zig-local-cache" \
      --global-cache-dir "$dir/.zig-global-cache" --summary all) > "$dir/build.txt" 2>&1
  echo "$c: zig build -Doptimize=ReleaseSmall: exit $?; $(grep -E '^Build Summary' "$dir/build.txt")"
  echo "$c: searchd $(wc -c < "$dir/out/bin/searchd" | tr -d ' ') B, sha256 $(shasum -a 256 "$dir/out/bin/searchd" | cut -c1-16)..."
done
if cmp "$scratch/searchd-$main/out/bin/searchd" "$scratch/searchd-$head/out/bin/searchd"; then
  echo "cmp: $main and $head searchd identical"
else
  echo "cmp: $main and $head searchd DIFFER"
fi
