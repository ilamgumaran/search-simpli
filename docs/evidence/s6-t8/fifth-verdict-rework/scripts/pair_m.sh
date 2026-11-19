#!/bin/bash
# One line N of ${SWEEP:-sites4.noindex}/pairs.txt: its (at most two) bound plants side by side, then the summary.
S=$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch
export SITES=$S/${SWEEP:-sites4.noindex} COMMIT=${COMMIT:-c88e11f}
names=$(sed -n "${1}p" $SITES/pairs.txt)
args=""; for n in $names; do args="$args b:$n"; done
bash $S/tools/site_pair.sh $args
python3 -I $S/tools/fails.py $SITES $names
