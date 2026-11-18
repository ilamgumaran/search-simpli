#!/bin/bash
# S6-T8 verifier (recheck): the v2 matrix with a planted build in place of the head, each in its own directory, and
# its rows compared with head2's (plcompare.py). plrun.sh VARIANT "CASES"
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
cd $V
v=$1; cases=$2
V2W=dmgv2-$v.noindex V2CASES="$cases" python3 -I dmg/v2matrix.py $v dmg/pl-$v.jsonl main pre7 pre4 > /dev/null 2> dmg/pl-$v.err || { echo "$v matrix failed"; tail -3 dmg/pl-$v.err; exit 1; }
python3 -I dmg/v2summary.py dmg/pl-$v.jsonl > dmg/pl-$v-summary.txt
python3 -I dmg/plcompare.py dmg/pl-$v.jsonl dmg/recheck-v2matrix.jsonl dmg/recheck-removed-count.jsonl dmg/recheck-removed-end.jsonl dmg/recheck-removed-last.jsonl > dmg/pl-$v-compare.txt
echo "== $v ($cases)"; tail -1 dmg/pl-$v-compare.txt
