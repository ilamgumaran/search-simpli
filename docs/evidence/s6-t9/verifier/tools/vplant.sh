#!/bin/bash
# S6-T9 verifier: one or two plants side by side, each in a fresh git archive of e3e8125 with its own Zig caches,
# the diff against an unplanted archive confirmed first, then Debug `zig build test --summary all`.
#   vplant.sh NAME [NAME]   (v-* from tools/vplants.py; others from the builder's plants_sites.py; `unplanted`)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T9
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
P=$V/plants.noindex
C=e3e8125
[ -d $P/none ] || { mkdir -p $P/none; git -C $W archive $C | tar -x -C $P/none; }
one() {
  n=$1; t=$P/src/$n
  [ -d $t ] && { echo "$n: copy exists"; return 5; }
  mkdir -p $t $P/out $P/diff $P/tmp $P/cache/$n/g $P/cache/$n/l
  git -C $W archive $C | tar -x -C $t
  nd=0
  if [ $n != unplanted ]; then
    case $n in v-*) python3 -I $V/tools/vplants.py $t $n > /dev/null;; *) python3 -I $W/scripts/prototypes/s6t9/plants_sites.py $t $n > /dev/null;; esac || { echo "$n: plant failed"; return 3; }
    diff -ru $P/none/zig/src $t/zig/src > $P/diff/$n.diff
    nd=$(grep -c '^[-+][^-+]' $P/diff/$n.diff)
    [ $nd = 0 ] && { echo "$n: NOT PLANTED"; return 4; }
  fi
  s=$(date +%s)
  (cd $t/zig && TMPDIR=$P/tmp zig build test --global-cache-dir $P/cache/$n/g --cache-dir $P/cache/$n/l --summary all > $P/out/$n.txt 2>&1)
  rc=$?
  echo "$n exit=$rc changed-lines=$nd secs=$(( $(date +%s) - s )) | $(grep -E '^Build Summary' $P/out/$n.txt) | $(grep -cE 'FAIL|error:' $P/out/$n.txt) fail/error lines"
}
for n in "$@"; do one $n > $P/res-$n.txt 2>&1 & done
wait
for n in "$@"; do cat $P/res-$n.txt; done
