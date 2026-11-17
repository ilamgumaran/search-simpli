#!/bin/bash
# S6-T7 verifier: index the six corpora with one searchd. mkidx.sh VARIANT OUTDIR
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T7-vscratch
S=$V/bin/$1/bin/searchd
O=$2
mkdir -p $O
C=$V/corpora.noindex
for c in timing-10k prose-10k tamil-10k; do $S index $C/$c --out $O/$c --filename-index > $O/$c.log; done
cd $V/src.noindex/head
$S index fixtures --out $O/fixtures --filename-index > $O/fixtures.log
$S index fixtures/family-folder --out $O/family --filename-index > $O/family.log
$S apply $O/j2 --changes $C/j2-changes.json --filename-index > $O/j2.log
cat $O/*.log
