#!/bin/bash
# S6-T8 verifier: the five v2-coded section 5 damages (dmg4.py v2 cases) on main's edge index (HYBLEX03), each read by main's
# and the head's searchd, then published over by each writer (main's, ab42899's, fb74582's, the head's), then read again.
# v2_first_publish.sh > dmg/results-v2.txt
set -u
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
cd $V
W="தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்தமிழ்"
for c in v2_zero_length v2_past_text v2_count_plus1_last v2_leftover v2_max_varints; do
  src=dmg.noindex/r2-$c
  [ -d $src ] || python3 -I dmg/dmg4.py make idx.noindex/main/edge $src $c > /dev/null
  echo "== $c"
  for r in main head; do printf "  read %-5s find: " $r; bin/$r/bin/searchd find $src "$W" --json 2>&1 | python3 -I -c "
import json,sys
t=sys.stdin.read()
try: print([(h['path'],h['match_offsets']) for h in json.loads(t)['hits']])
except Exception: print(t.strip()[-80:])"; done
  for w in main ab4 fb head; do
    d=$src.pub-$w
    [ -d $d ] || cp -R $src $d
    out=$(bin/$w/bin/searchd index corpora.noindex/edge --out $d --update --filename-index 2>&1 | tail -1 | cut -c1-40)
    printf "  publish by %-4s: %-42s then head find: " $w "$out"
    bin/head/bin/searchd find $d "$W" --json 2>&1 | python3 -I -c "
import json,sys
t=sys.stdin.read()
try: print([(h['path'],h['match_offsets']) for h in json.loads(t)['hits']])
except Exception: print(t.strip()[-80:])"
  done
done
printf "== clean head index: "; bin/head/bin/searchd find idx.noindex/head/edge "$W" --json | python3 -I -c "import json,sys; print([(h['path'],h['match_offsets']) for h in json.load(sys.stdin)['hits']])"
