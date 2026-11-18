#!/bin/bash
# S6-T8 verifier: fresh index of the modified corpus. mkmod.sh VARIANT OUT CORPUS
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
S=$V/bin/$1/bin/searchd; O=$2; c=$3; M=$V/corpora.noindex/mod
case $c in
  j2) $S apply $O --changes $M/j2-full.json --filename-index > /dev/null;;
  *) $S index $M/$c --out $O --filename-index > /dev/null;;
esac
