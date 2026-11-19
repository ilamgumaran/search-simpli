#!/bin/bash
# S6-T8 verifier: every v4 damage case on one head index. runall.sh SRCSET CORPUS TAG
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
cd $V
case $2 in fixtures) cdir=src.noindex/head/fixtures;; family) cdir=src.noindex/head/fixtures/family-folder;; *) cdir=corpora.noindex/$2;; esac
for k in $(python3 -I dmg/dmg4.py list); do
  case $k in v2_*) continue;; esac
  out=dmg.noindex/$3-$k
  info=$(python3 -I dmg/dmg4.py make idx.noindex/$1/$2 $out $k) || { echo "{\"case\":\"$k\",\"make\":\"failed\"}"; continue; }
  words=$(echo "$info" | python3 -I -c "import json,sys; print(json.dumps(json.load(sys.stdin)['words']))")
  res=$(python3 -I dmg/check4.py libs/${LIBV:-head}/libsearch_simpli.dylib bin/${LIBV:-head}/bin/searchd $out "$words" $cdir)
  echo "{\"info\": $info, \"result\": $res}"
done
