#!/bin/bash
# S6-T9 verifier: the case lists for dmgrun.sh. dmgcases.sh SRCSET CORPUS BUILD GROUP...
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
STATE="S1-0 S1-2 S1-3 S3-count S3-max S4-first S4-mid S4-last S4-down S5 count-bound zero-mtime zero-moved zero-reserved bit7 bit31 trailing hdr-version2 hdr-version4"
MAN="M1 M2 M3-clear8 M4-clear9 bit10"
CAT="C1-first C1-mid C1-last C2-first C2-mid C2-last cat-version5 cat-version3 cat-trailing docs-version6 cat-flip cat-pathswap cat-lines"
s=$1; c=$2; b=$3; shift 3; L=""
for g in "$@"; do case $g in state) L="$L $STATE";; man) L="$L $MAN";; cat) L="$L $CAT";; *) L="$L $g";; esac; done
bash $V/tools/dmgrun.sh $s $c $b $L
