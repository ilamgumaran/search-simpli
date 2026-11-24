#!/bin/zsh
# S6-T24 verifier (Verdict 3, ruling 3): the default zig build test and the Python scan tests, rerun while the
# verifier's probes load the machine. Each zig run gets a new seed, so the test run steps are not taken from the
# cache. Usage: load_tests.sh REPO (with the pinned Zig on PATH); bound it from outside (the verifier used
# bounded.py, 5,400 s).
R=$1
unset SEARCH_SIMPLI_LIBRARY_PATH
for seed in 0x5eed0001 0x5eed0002 0x5eed0003; do
  echo "== zig build test --seed $seed (load: $(sysctl -n vm.loadavg))"
  (cd $R/zig && zig build test --summary all --seed $seed 2>&1 | grep -E "Build Summary|error:|FAIL|expected|panic" | head -20; echo "exit ${pipestatus[1]}")
done
for n in 1 2 3; do
  echo "== python -m unittest tests.test_scan, run $n (load: $(sysctl -n vm.loadavg))"
  (cd $R && env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests -p test_scan.py 2>&1 | grep -E "^Ran|^OK|FAILED|Error|four times" | head -20)
done
echo finished
