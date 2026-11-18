#!/bin/bash
# S6-T8 verifier: copy index SRC to OUT and update it once (no change) with searchd VARIANT. upd.sh VARIANT SRC OUT CORPUS
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
S=$V/bin/$1/bin/searchd; SRC=$2; OUT=$3; c=$4
C=$V/corpora.noindex; F=$V/src.noindex/head/fixtures
[ -e $OUT ] || cp -R $SRC $OUT
case $c in
  j2) $S apply $OUT --changes $C/j2-empty.json --filename-index;;
  fixtures) $S index $F --out $OUT --update --filename-index;;
  family) $S index $F/family-folder --out $OUT --update --filename-index;;
  *) $S index $C/$c --out $OUT --update --filename-index;;
esac | tail -1 | cut -c1-60
