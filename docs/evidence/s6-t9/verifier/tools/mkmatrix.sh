#!/bin/bash
# S6-T9 verifier: the index sets for same answers and change detection, one corpus. mkmatrix.sh CORPUS
# Each line of $V/matrix/<corpus>.log: the set, the writer, the report's last line.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
c=$1; I=$V/idx.noindex; C=$V/corpora.noindex; F=$V/src.noindex/main/fixtures; L=$V/matrix/$c.log
mkdir -p $V/matrix
folder() { case $1 in family) echo $F/family-folder;; fixtures) echo $F;; *) echo $C/$1;; esac; }
chgfolder() { echo $C/chg/$1; }
# upd BUILD SRCSET DSTSET kind(same|chg)
upd() {
  b=$1; src=$I/$2/$c; dst=$I/$3/$c; kind=$4; S=$V/bin/$b/bin/searchd
  [ -e $dst ] && { echo "$3 exists" >> $L; return; }
  mkdir -p $I/$3; cp -c -R $src $dst
  if [ $c = j2 ]; then
    ch=$C/chg/j2-empty.json; [ $kind = chg ] && ch=$C/chg/j2-chg.json
    r=$($S apply $dst --changes $ch --filename-index 2>&1 | tail -1)
  else
    fo=$(folder $c); [ $kind = chg ] && fo=$(chgfolder $c)
    r=$($S index $fo --out $dst --update --filename-index 2>&1 | tail -1)
  fi
  echo "$3 by $b ($kind from $2): $r" >> $L
}
fresh() {  # fresh BUILD SET FOLDERKIND
  b=$1; dst=$I/$2/$c; S=$V/bin/$b/bin/searchd
  [ -e $dst ] && return; mkdir -p $I/$2
  if [ $c = j2 ]; then
    $S apply $dst --changes $C/j2-changes.json --filename-index > /dev/null
    [ $3 = chg ] && $S apply $dst --changes $C/chg/j2-chg.json --filename-index > /dev/null   # j2: no folder; fresh+chg
  else
    fo=$(folder $c); [ $3 = chg ] && fo=$(chgfolder $c)
    $S index $fo --out $dst --filename-index > /dev/null
  fi
  echo "$2 fresh by $b ($3)" >> $L
}
for p in pre8 pre7 pre4; do fresh $p $p same; done
fresh head headchg chg; fresh main mainchg chg
upd main main m1-main same; upd head main m1-head same
upd main main c1-main chg;  upd head main c1-head chg
upd main m1-main c2-main chg; upd head m1-head c2-head chg
upd head head h1-head same
for p in pre8 pre7 pre4; do upd head $p $p-head same; upd head $p $p-headc chg; done
echo "matrix $c done"
