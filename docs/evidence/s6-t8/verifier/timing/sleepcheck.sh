#!/bin/bash
# S6-T8 verifier: pmset -g log lines (Sleep / Wake / DarkWake / Maintenance) between each run's first start and last end in runlog.txt.
# sleepcheck.sh RUN  -> the window and every matching pmset line inside it
T=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch/tim
run=$1
start=$(grep " start run$run " $T/runlog.txt | head -1 | cut -c1-19)
end=$(grep " end run$run " $T/runlog.txt | tail -1 | cut -c1-19)
echo "run$run window: $start .. $end"
pmset -g log | awk -v s="$start" -v e="$end" 'substr($0,1,19) >= s && substr($0,1,19) <= e && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake")' | cut -c1-100
