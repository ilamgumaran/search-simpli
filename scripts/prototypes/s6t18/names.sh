#!/usr/bin/env bash
# S6-T18 ruling 5 (S6-T16's proofs.sh `names`, one commit and one mode per call, so each call stays short):
#   scripts/prototypes/s6t18/names.sh COMMIT MODE SCRATCH
# In a fresh `git archive COMMIT` (SCRATCH/names-COMMIT-MODE, its own local and global caches):
# check_test_counts.py --run -- -Doptimize=MODE (zig build test --summary all, both guards), then every test binary
# of that build run directly from zig/, one sorted line per test (times and growth ratios shown as N), into
# names.txt; and zig build test-abi --summary all in the same mode. Zig on PATH. Never removes anything.
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
commit="$1"; mode="$2"; scratch="$3"
dir="$scratch/names-$commit-$mode"
if [ -e "$dir" ]; then echo "names.sh: $dir exists" >&2; exit 2; fi
mkdir -p "$dir" && git -C "$repo" archive "$commit" | tar -x -C "$dir"
caches="--cache-dir $dir/.zig-local-cache --global-cache-dir $dir/.zig-global-cache"
# shellcheck disable=SC2086
(cd "$dir" && python3 -I scripts/check_test_counts.py --root "$dir" --run -- -Doptimize="$mode" $caches) > "$dir/counts.txt" 2>&1
echo "$commit $mode: check_test_counts.py --run -- -Doptimize=$mode: exit $?"
grep -E "Build Summary|run test" "$dir/counts.txt" | grep -v " w$" | sed -E 's/ [0-9.]+(ms|s|m|us) MaxRSS:[0-9]+[KMG]//'
grep -E "^check_(test_counts|layers):" "$dir/counts.txt"
for step in core operations interfaces tests test; do
  bin=$(find "$dir/.zig-local-cache/o" -type f -name "$step" -perm -u+x | head -1)
  [ -n "$bin" ] || { echo "MISSING binary $step"; continue; }
  (cd "$dir/zig" && "$bin" 2>&1) | sed -E -e 's/^[0-9]+\/[0-9]+ //' -e 's/[0-9]+(\.[0-9]+)? ?ms/N ms/g' -e 's/growth [0-9.]+x/growth Nx/g' \
    | sed "s/^/$step: /"
done | LC_ALL=C sort > "$dir/names.txt"
echo "$commit $mode: $(wc -l < "$dir/names.txt" | tr -d ' ') lines; $(grep -c 'OK$' "$dir/names.txt") OK," \
     "$(grep -c 'SKIP$' "$dir/names.txt") SKIP, $(grep -cE 'FAIL|error' "$dir/names.txt") FAIL or error"
# shellcheck disable=SC2086
(cd "$dir/zig" && zig build test-abi -Doptimize="$mode" --summary all $caches) > "$dir/abi.txt" 2>&1
echo "$commit $mode: zig build test-abi: exit $?; $(grep -E 'Build Summary' "$dir/abi.txt"); $(grep -E 'abi_test' "$dir/abi.txt" | tail -1)"
