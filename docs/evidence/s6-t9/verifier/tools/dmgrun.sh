#!/bin/bash
# S6-T9 verifier: damage cases. dmgrun.sh SRCSET CORPUS BUILD CASE... -> one JSON line per case in $V/dmg.noindex/results.jsonl
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
s=$1; c=$2; b=$3; shift 3
for k in "$@"; do
  d=$V/dmg.noindex/$s-$c-$k-$b
  if python3 -I $V/tools/damage.py $V $V/idx.noindex/$s/$c $d $k > /dev/null; then
    python3 -I $V/tools/observe.py $V $b $d $c | python3 -I -c "import json,sys; x=json.loads(sys.stdin.read()); x['case']='$k'; x['set']='$s'; print(json.dumps(x, ensure_ascii=False))" >> $V/dmg.noindex/results.jsonl
  else echo "{\"case\": \"$k\", \"set\": \"$s\", \"corpus\": \"$c\", \"damage\": \"failed\"}" >> $V/dmg.noindex/results.jsonl; fi
done
