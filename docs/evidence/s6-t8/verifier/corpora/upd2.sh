#!/bin/bash
# S6-T8 verifier: copy SRC to OUT and update it with VARIANT from the modified corpus (one file changed). upd2.sh VARIANT SRC OUT CORPUS
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
S=$V/bin/$1/bin/searchd; SRC=$2; OUT=$3; c=$4; M=$V/corpora.noindex/mod
[ -e $OUT ] || cp -R $SRC $OUT
case $c in
  j2) $S apply $OUT --changes $M/j2-one.json --filename-index;;
  *) $S index $M/$c --out $OUT --update --filename-index;;
esac | tail -1 | cut -c1-90
