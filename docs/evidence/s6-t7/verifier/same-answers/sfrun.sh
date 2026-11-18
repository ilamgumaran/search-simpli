#!/bin/bash
# S6-T7 verifier: surfaces for one searchd and one index set over seven corpora. sfrun.sh BIN IDXSET TAG
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T7-vscratch
cd $V
F=$V/src.noindex/head/fixtures
for c in j2 edge family fixtures timing-10k prose-10k tamil-10k; do
  case $c in j2) fo=-;; fixtures) fo=$F;; family) fo=$F/family-folder;; *) fo=$V/corpora.noindex/$c;; esac
  python3 -I dec/surf.py bin/$1/bin/searchd idx.noindex/$2/$c $fo sf/$c-$3.jsonl
done
