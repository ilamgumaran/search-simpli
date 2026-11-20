#!/bin/bash
# run.sh NAME : index prose-10k and fixtures with bin/NAME searchd, an --update round on a fixtures copy, then the 50 queries
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
S=$HOME/workspace/repos/search-simpli-wt/S6-T9m-vscratch.noindex
B=$S/bin/$1/bin/searchd; O=$S/idx/$1; Q=$S/q/$1
[ -e $O ] && { echo "$O exists"; exit 1; }
mkdir -p $O $Q
P=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch/corpora.noindex/prose-10k
F=$S/src/new/fixtures
$B index $P --out $O/prose --filename-index > $O/prose.log 2>&1; echo "prose index exit $?"
$B index $F --out $O/fixtures --filename-index > $O/fixtures.log 2>&1; echo "fixtures index exit $?"
# update round: a private copy of fixtures, indexed, then changed, then --update
W=$S/work/fx; rm -rf "$S/work/fx"; mkdir -p $S/work; cp -R $F $W
$B index $W --out $O/upd --filename-index > $O/upd1.log 2>&1; echo "upd index exit $?"
first=$(find $W -type f -name '*.md' | sort | head -1); second=$(find $W -type f -name '*.md' | sort | sed -n 2p)
printf '\nAn added line about orchards and courage.\n' >> "$first"; rm "$second"; printf '# New note\n\nA fresh note about recipes and budget.\n' > $W/new-note.md
$B index $W --out $O/upd --update --filename-index > $O/upd2.log 2>&1; echo "upd --update exit $?"
$B index $W --out $O/upd --update --filename-index > $O/upd3.log 2>&1; echo "upd --update (unchanged) exit $?"
i=0
while IFS='|' read -r kind text; do
  i=$((i+1)); n=$(printf '%02d' $i)
  if [ $kind = p ]; then $B query $O/prose "$text" --json --top-k 10 > $Q/$n.out 2>&1; else $B query $O/fixtures "$text" --json --top-k 10 > $Q/$n.out 2>&1; fi
  echo "exit $?" >> $Q/$n.out
done < $S/tools/queries.txt
echo "queries $i"
