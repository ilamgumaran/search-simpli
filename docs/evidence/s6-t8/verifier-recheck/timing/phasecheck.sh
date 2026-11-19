#!/bin/bash
# S6-T8 verifier (recheck): the last phase in runlog.txt: its window, row count, and every pmset Sleep/Wake/DarkWake line inside it.
T=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch/tim2
s=$(tail -2 $T/runlog.txt | head -1); e=$(tail -1 $T/runlog.txt)
echo "phase: ${s:20} .. ${e:20} (${s:0:19} .. ${e:0:19})"
pmset -g log | awk -v s="${s:0:19}" -v e="${e:0:19}" 'substr($0,1,19) >= s && substr($0,1,19) <= e && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake")' | cut -c1-100
echo "sleep lines: $(pmset -g log | awk -v s="${s:0:19}" -v e="${e:0:19}" 'substr($0,1,19) >= s && substr($0,1,19) <= e && ($4 == "Sleep" || $4 == "Wake" || $4 == "DarkWake")' | wc -l | tr -d ' ')"
