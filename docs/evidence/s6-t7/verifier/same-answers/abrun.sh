#!/bin/bash
# S6-T7 verifier: C ABI dumps for one (lib, index set) over the six corpora. abrun.sh LIB IDXSET TAG
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T7-vscratch
cd $V
for c in j2 family fixtures timing-10k prose-10k tamil-10k; do
  python3 -I dec/abi_dump.py libs/$1/libsearch_simpli.dylib idx.noindex/$2/$c $c corpora.noindex src.noindex/head/fixtures ab/$c-$3.jsonl
done
