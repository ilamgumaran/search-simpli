#!/bin/bash
# S6-T9 verifier: the plant pairs left when chain.sh was stopped at 20:48 (builder plants first), one pair at a time.
unset SEARCH_SIMPLI_LIBRARY_PATH; export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch; cd $V
log() { echo "$(date +%H:%M:%S) load $(sysctl -n vm.loadavg | tr -d '{}') $*" >> $V/chain.txt; }
log "chain2 start"
for pair in "s-S2 b-S3-loose" "b-S4-tight s-S5-separator" "b-count-bound-loose s-v2-bit6" "s-ref-zero-moved s-section-v3-version" \
            "s-writer-v1-source s-M2" "v-refers-pending v-refers-hash" "v-apply-swallow v-ref-mtime"; do
  bash tools/vplant.sh $pair >> $V/plants.noindex/results.txt; log "plants $pair: $(tail -2 $V/plants.noindex/results.txt | cut -c1-60 | tr '\n' ' ')"
done
log "chain2 done"
