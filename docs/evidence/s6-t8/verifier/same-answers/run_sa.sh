#!/bin/bash
# S6-T8 verifier: ABI dump + find dump for one (lib, index set) on the listed corpora. run_sa.sh LIB IDXSET TAG [mod] corpora...
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
cd $V
lib=$1; set_=$2; tag=$3; shift 3
CR=corpora.noindex; FX=src.noindex/head/fixtures
if [ "$1" = mod ]; then CR=corpora.noindex/mod; shift; fi
for c in "$@"; do
  fx=$FX; [ "$CR" != corpora.noindex ] && [ $c = family ] && fx=$CR/famroot
  [ "$CR" != corpora.noindex ] && [ $c = fixtures ] && fx=$CR/fixtures
  a=$(python3 -I sa/abi_dump.py libs/$lib/libsearch_simpli.dylib idx.noindex/$set_/$c $c $CR $fx ab/$c-$tag.jsonl)
  f=$(python3 -I sa/find_dump.py libs/$lib/libsearch_simpli.dylib idx.noindex/$set_/$c sa/q-$c.json ab/find-$c-$tag.jsonl)
  echo "$tag $c abi: $a find: $f"
done
