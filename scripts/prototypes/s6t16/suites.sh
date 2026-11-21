#!/usr/bin/env bash
# S6-T16: the non-Zig suites, one after another.
#
#   scripts/prototypes/s6t16/suites.sh COMMIT SCRATCH EVIDENCE
#
# Python with and without Zig, in the worktree; J2 on the Python reference and on COMMIT's
# ReleaseSmall searchd (SCRATCH/searchd-COMMIT, made by proofs.sh searchd); Dart in a fresh
# git archive of COMMIT with its committed natives; the three checkers and whitespace.
# Zig and Dart on PATH. Never removes anything.
set -uo pipefail
commit="$1"; scratch="$2"; evidence="$3"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
cd "$repo" || exit 2
strip() { sed -e "s#$scratch#<scratch>#g" -e "s#$repo#<repo>#g"; }

{
  echo "# Python with Zig on PATH (env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests), worktree at $commit"
  env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests > "$scratch/python-zig.txt" 2>&1
  echo "exit $?"; grep -E "^Ran |^OK|^FAILED" "$scratch/python-zig.txt"
  echo "# Python without Zig (SEARCH_SIMPLI_NO_ZIG=1)"
  SEARCH_SIMPLI_NO_ZIG=1 python3 -m unittest discover -s tests > "$scratch/python-nozig.txt" 2>&1
  echo "exit $?"; grep -E "^Ran |^OK|^FAILED" "$scratch/python-nozig.txt"
} 2>&1 | strip > "$evidence/python.txt"

{
  echo "# J2, Python reference"
  python3 scripts/relevance_smoke.py --pack j2 --output "$scratch/j2.json" > "$scratch/j2-ref.txt" 2>&1
  echo "relevance_smoke exit $?"
  python3 scripts/j2_gate.py "$scratch/j2.json" 2>&1 | tail -1
  echo "# J2, native: $commit's ReleaseSmall searchd (fresh archive)"
  PYTHONHASHSEED=0 python3 scripts/ci_j2_native.py run --searchd "$scratch/searchd-$commit/out/bin/searchd" \
    --expect-queries 290 --output "$scratch/j2-native.json" 2>&1 | tail -4
  echo "run exit ${PIPESTATUS[0]}"
  python3 scripts/ci_j2_native.py differences "$scratch/j2-native.json" 2>&1 | tail -2
  python3 scripts/j2_gate.py "$scratch/j2-native.json" 2>&1 | tail -1
} 2>&1 | strip | cut -c1-400 > "$evidence/j2.txt"

{
  dir="$scratch/dart-$commit"
  if [ ! -d "$dir" ]; then mkdir -p "$dir" && git archive "$commit" | tar -x -C "$dir"; fi
  echo "# Dart: fresh git archive of $commit, its committed natives; $(dart --version 2>&1)"
  (cd "$dir/bindings/dart/search_simpli" && dart pub get > "$dir/pub.txt" 2>&1; echo "pub get exit $?"
   dart analyze lib test 2>&1 | tail -2; echo "analyze exit ${PIPESTATUS[0]}"
   dart test > "$dir/test.txt" 2>&1; echo "dart test exit $?"; tail -1 "$dir/test.txt")
} 2>&1 | strip > "$evidence/dart.txt"

{
  echo "# the three checkers and whitespace, worktree at $commit"
  python3 scripts/check_layers.py; echo "check_layers exit $?"
  python3 scripts/check_requirements.py; echo "check_requirements exit $?"
  python3 -I scripts/check_no_home_paths.py; echo "check_no_home_paths exit $?"
  python3 -m unittest tests.test_check_layers tests.test_check_test_counts 2>&1 | tail -3
  git diff --check 10f3d40 "$commit"; echo "git diff --check 10f3d40 $commit exit $?"
} 2>&1 | strip > "$evidence/checkers.txt"
