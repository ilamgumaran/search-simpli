#!/bin/bash
# S6-T9 verifier: pmset -g log Sleep / Wake / DarkWake lines between a run's first start and last end in runlog.txt.
# sleepcheck2.sh RUN (set 2)
T=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch/tim2
run=$1
start=$(grep " start run$run " $T/runlog.txt | head -1 | cut -c1-19)
end=$(grep -E " (end|gate-stop) run$run " $T/runlog.txt | tail -1 | cut -c1-19)
echo "run$run window: $start .. $end"
pmset -g log | awk -v s="$start" -v e="$end" 'substr($0,1,19) >= s && substr($0,1,19) <= e && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake")' | cut -c1-100
echo "sleep/wake lines: $(pmset -g log | awk -v s="$start" -v e="$end" 'substr($0,1,19) >= s && substr($0,1,19) <= e && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake")' | wc -l | tr -d ' ')"
