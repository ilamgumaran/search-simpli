#!/bin/bash
# S6-T9 verifier: index corpora with one build's searchd. mkidx.sh VARIANT OUTDIR [corpora...]
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
S=$V/bin/$1/bin/searchd
O=$2; shift 2
list=${*:-"j2 family fixtures timing-10k prose-10k tamil-10k"}
mkdir -p $O
C=$V/corpora.noindex
F=$V/src.noindex/main/fixtures
for c in $list; do
  case $c in
    j2) $S apply $O/j2 --changes $C/j2-changes.json --filename-index > $O/j2.log;;
    fixtures) $S index $F --out $O/fixtures --filename-index > $O/fixtures.log;;
    family) $S index $F/family-folder --out $O/family --filename-index > $O/family.log;;
    *) $S index $C/$c --out $O/$c --filename-index > $O/$c.log;;
  esac
done
echo "indexed $1 -> $O ($list) $(date +%T)"
