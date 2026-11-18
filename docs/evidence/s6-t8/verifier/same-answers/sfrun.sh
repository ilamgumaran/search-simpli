#!/bin/bash
# S6-T8 verifier: surfaces for one searchd and one index set. sfrun.sh BIN IDXSET TAG [mod] corpora...
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
cd $V
b=$1; s=$2; t=$3; shift 3
F=$V/src.noindex/head/fixtures; C=$V/corpora.noindex
if [ "$1" = mod ]; then F=$C/mod/fixtures; FAM=$C/mod/family; C=$C/mod; shift; else FAM=$F/family-folder; fi
mkdir -p sf
for c in "$@"; do
  case $c in j2) fo=-;; fixtures) fo=$F;; family) fo=$FAM;; *) fo=$C/$c;; esac
  python3 -I sa/surf.py bin/$b/bin/searchd idx.noindex/$s/$c $fo sf/$c-$t.jsonl sa/q-$c.json
done
