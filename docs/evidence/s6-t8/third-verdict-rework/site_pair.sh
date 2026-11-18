#!/bin/bash
# Two site plants side by side, then wait for both.
S=$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch
for n in "$@"; do bash $S/tools/run_site_plant.sh $n > ${SITES:-$S/sites.noindex}/res-${n#v:}.txt 2>&1 & done
wait
for n in "$@"; do cat ${SITES:-$S/sites.noindex}/res-${n#v:}.txt; done
