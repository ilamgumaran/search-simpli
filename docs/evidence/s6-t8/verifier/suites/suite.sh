#!/bin/bash
# S6-T8 verifier: one suite on a fresh git archive of 6b340b4 (src.noindex/suite), own Zig caches, log in suites/NAME.txt.
# suite.sh NAME   (zig-debug | zig-rs | abi-debug | abi-rs | guard | py-nozig | py-zig | py-surfaces | relevance | j2-py | j2-native | dart | checks)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$HOME/development/flutter/bin:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
S=$V/src.noindex/suite
C=$V/cache.noindex/suite
mkdir -p $C/g $C/l $V/tmp
export TMPDIR=$V/tmp ZIG_GLOBAL_CACHE_DIR=$C/g ZIG_LOCAL_CACHE_DIR=$C/l
name=$1; log=$V/suites/$name.txt
z="--global-cache-dir $C/g --cache-dir $C/l"
s=$(date +%s)
case $name in
  zig-debug) (cd $S/zig && zig build test $z --summary all) > $log 2>&1;;
  zig-rs) (cd $S/zig && zig build test -Doptimize=ReleaseSmall $z --summary all) > $log 2>&1;;
  abi-debug) (cd $S/zig && zig build test-abi $z --summary all) > $log 2>&1;;
  abi-rs) (cd $S/zig && zig build test-abi -Doptimize=ReleaseSmall $z --summary all) > $log 2>&1;;
  guard) (cd $S/zig && for m in Debug ReleaseSmall; do zig test -O$m -lc src/filename_complexity_test.zig --test-filter 'filename query complexity' $z; done) > $log 2>&1;;
  py-nozig) (cd $S && SEARCH_SIMPLI_NO_ZIG=1 python3 -m unittest discover -s tests) > $log 2>&1;;
  py-zig) (cd $S && env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests) > $log 2>&1;;
  py-surfaces) (cd $S && env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest -v tests.test_mcp tests.test_folder_surfaces tests.test_cli_process) > $log 2>&1;;
  relevance) (cd $S && python3 relevance_smoke.py fixtures/relevance-smoke/corpus fixtures/relevance-smoke/judgments.json --mode lexical --top-k 10 --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1 && python3 scripts/relevance_smoke.py --pack family-folder) > $log 2>&1;;
  j2-py) (cd $S && PYTHONHASHSEED=0 python3 scripts/relevance_smoke.py --pack j2 --output $V/suites/j2-py.json && python3 scripts/j2_gate.py $V/suites/j2-py.json) > $log 2>&1;;
  j2-native) (cd $S && PYTHONHASHSEED=0 PYTHONIOENCODING=utf-8 python3 scripts/ci_j2_native.py run --searchd $V/bin/head/bin/searchd --expect-queries 290 --output $V/suites/j2-native.json && PYTHONIOENCODING=utf-8 python3 scripts/ci_j2_native.py differences $V/suites/j2-native.json && PYTHONIOENCODING=utf-8 python3 scripts/j2_gate.py $V/suites/j2-native.json) > $log 2>&1;;
  dart) (cd $S/bindings/dart/search_simpli && dart analyze lib test && dart test) > $log 2>&1;;
  checks) (cd $S && python3 scripts/check_layers.py && python3 scripts/check_requirements.py && python3 -I scripts/check_no_home_paths.py) > $log 2>&1;;
esac
rc=$?
echo "$name exit=$rc $(( $(date +%s)-s ))s | $(grep -E 'Build Summary|^Ran |^OK|^FAILED|gate:|All tests passed|Some tests failed|No issues found' $log | tail -3 | tr '\n' ' ')"
