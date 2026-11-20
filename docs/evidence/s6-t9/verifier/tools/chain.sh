#!/bin/bash
# S6-T9 verifier: the untimed checks left, one after another (no timing in this chain). Log: $V/chain.txt
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch; cd $V
log() { echo "$(date '+%H:%M:%S') load $(sysctl -n vm.loadavg | cut -d' ' -f2-4) $*" >> $V/chain.txt; }
log "start"
xargs -P 4 -L 1 bash tools/sajob.sh < sa/jobs-part-ad; log "same-answer batch ad done"
python3 -I tools/sacmp.py $V > sa/compare.txt; log "compare: $(tail -1 sa/compare.txt)"
python3 -I tools/kill/kill.py $V cli-first 20 9101 $V/kill.noindex-results.jsonl > /dev/null 2>&1; log "kill cli-first: $(tail -1 $V/kill.noindex-results.jsonl | cut -c1-200)"
python3 -I tools/kill/kill.py $V abi-v6 10 9102 $V/kill.noindex-results.jsonl > /dev/null 2>&1; log "kill abi-v6: $(tail -1 $V/kill.noindex-results.jsonl | cut -c1-200)"
bash tools/natives.sh; log "natives: $(grep -c identical suites/natives.txt) identical, $(grep -c DIFFERS suites/natives.txt) differ"
for s in zig-rs abi-debug abi-rs guard py-nozig py-zig py-git2 dart relevance j2-py j2-native checks; do bash tools/suite.sh $s >> $V/suites/summary.txt; log "suite $(tail -1 $V/suites/summary.txt | cut -c1-120)"; done
for pair in "v-M3-oneway v-M4-manifest-oneway" "v-M4-load-oneway v-ref-labels" "v-refers-pending v-refers-hash" "v-apply-swallow v-ref-mtime" \
            "s-S2 b-S3-loose" "b-S4-tight s-S5-separator" "b-count-bound-loose s-v2-bit6" "s-ref-zero-moved s-section-v3-version" \
            "s-writer-v1-source s-M2" "s-M4-load s-C2" "s-documents-v6 s-carried-inspect" "b-refers-order d-compat-s6t9-test" \
            "b-walk-headroom-loose s-table-doc-version"; do
  bash tools/vplant.sh $pair >> $V/plants.noindex/results.txt; log "plants $pair: $(tail -2 $V/plants.noindex/results.txt | cut -c1-60 | tr '\n' ' ')"
done
log "end"
