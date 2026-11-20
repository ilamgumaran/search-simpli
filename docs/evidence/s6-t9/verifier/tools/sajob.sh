#!/bin/bash
# S6-T9 verifier: one same-answer job. sajob.sh KIND BUILD SET CORPUS -> $V/sa/KIND/CORPUS/SET@BUILD.jsonl
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
k=$1; b=$2; s=$3; c=$4; I=$V/idx.noindex/$s/$c; O=$V/sa/$k/$c; mkdir -p $O; out=$O/$s@$b.jsonl
[ -e $out ] && exit 0
F=$V/src.noindex/main/fixtures
case $c in family) fo=$F/family-folder;; fixtures) fo=$F;; j2) fo=--;; *) fo=$V/corpora.noindex/$c;; esac
case $k in
  abi) python3 -I $V/tools/sa/abi_dump.py $V/libs/$b/libsearch_simpli.dylib $I $c $V/corpora.noindex $F $out.part > $out.log 2>&1;;
  find) python3 -I $V/tools/sa/find_dump.py $V/libs/$b/libsearch_simpli.dylib $I $V/tools/sa/q-$c.json $out.part > $out.log 2>&1;;
  surf) python3 -I $V/tools/sa/surf.py $V/bin/$b/bin/searchd $I $fo $out.part $V/tools/sa/q-$c.json > $out.log 2>&1;;
esac
rc=$?; [ $rc = 0 ] && mv $out.part $out || echo "FAILED $k $b $s $c rc=$rc" >> $V/sa/failed.txt
