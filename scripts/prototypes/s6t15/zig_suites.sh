#!/usr/bin/env bash
# S6-T15: Zig builds and suites in fresh `git archive` copies, each with its own caches.
#
#   scripts/prototypes/s6t15/zig_suites.sh searchd COMMIT MAIN SCRATCH   # ReleaseSmall searchd of both, cmp
#   scripts/prototypes/s6t15/zig_suites.sh tests COMMIT SCRATCH          # zig build test, Debug and ReleaseSmall
#   scripts/prototypes/s6t15/zig_suites.sh abi COMMIT SCRATCH            # zig build test-abi, Debug and ReleaseSmall
#
# Zig on PATH. Builds run one after another, never two at once. Never removes anything.
set -uo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"

fresh() {  # fresh COMMIT DIR: a git archive of COMMIT in DIR (made once)
  if [ ! -d "$2" ]; then mkdir -p "$2" && git -C "$repo" archive "$1" | tar -x -C "$2"; fi
}

zigb() {  # zigb DIR ARGS...: zig build in DIR/zig with DIR's own caches
  local dir="$1"; shift
  (cd "$dir/zig" && zig build "$@" --cache-dir "$dir/.zig-local-cache" --global-cache-dir "$dir/.zig-global-cache")
}

summary() {  # summary FILE: the Build Summary and the step lines
  grep -E "Build Summary|run test|abi_test|run abi_test" "$1" | grep -v " w$" | sed -E 's/ [0-9.]+(ms|s|m|us) MaxRSS:[0-9]+[KMG]//'
}

case "$1" in
  searchd)
    commit="$2"; main="$3"; scratch="$4"
    for c in "$commit" "$main"; do
      dir="$scratch/searchd-$c"; fresh "$c" "$dir"
      zigb "$dir" -Doptimize=ReleaseSmall --prefix "$dir/out" > "$dir/build.txt" 2>&1
      echo "$c: zig build -Doptimize=ReleaseSmall exit $?; searchd $(wc -c < "$dir/out/bin/searchd" | tr -d ' ') B, sha256 $(shasum -a 256 "$dir/out/bin/searchd" | cut -c1-16)..."
    done
    if cmp "$scratch/searchd-$commit/out/bin/searchd" "$scratch/searchd-$main/out/bin/searchd"; then
      echo "searchd ReleaseSmall: $commit and $main cmp-identical"
    else
      echo "searchd ReleaseSmall: $commit and $main DIFFER"
    fi
    ;;
  tests|abi)
    commit="$2"; scratch="$3"; dir="$scratch/suites-$commit"; fresh "$commit" "$dir"
    step=test; [ "$1" = abi ] && step=test-abi
    for mode in Debug ReleaseSmall; do
      zigb "$dir" "$step" -Doptimize="$mode" --summary all > "$dir/$step-$mode.txt" 2>&1
      echo "zig build $step -Doptimize=$mode --summary all: exit $?"
      summary "$dir/$step-$mode.txt"
    done
    ;;
esac
