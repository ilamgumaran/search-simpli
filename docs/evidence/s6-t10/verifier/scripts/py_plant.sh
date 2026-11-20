#!/bin/bash
# S6-T10 verifier: one ruling-1 plant in its own copy of the head's Python tree, diffed against the
# unplanted base, then the skill tests without Zig (and, with ZIG=1, test_example_loop with a searchd).
# py_plant.sh NAME
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V="$HOME/workspace/repos/search-simpli-wt/S6-T10-vscratch"
BASE="$V/py.noindex/base"
NAME="$1"
DEST="$V/py.noindex/$NAME"
OUT="$V/ev/py-plants/$NAME.txt"
mkdir -p "$V/ev/py-plants"
if [ -e "$DEST" ]; then echo "copy $NAME exists already" >&2; exit 2; fi
cp -R "$BASE" "$DEST"
{
  python3 -I "$V/scripts/py_plants.py" "$DEST" "$NAME" || exit 3
  echo "--- diff base $NAME"
  (cd "$V/py.noindex" && diff -r -u base "$NAME")
  echo "--- SEARCH_SIMPLI_NO_ZIG=1 tests.test_example_loop.SkillDocumentTests"
  (cd "$DEST" && SEARCH_SIMPLI_NO_ZIG=1 python3 -I -m unittest discover -v -s tests -p test_example_loop.py -k SkillDocumentTests 2>&1 | sed -e "s#$V#<vscratch>#g" -e "s#$HOME#<home>#g"; exit ${PIPESTATUS[0]})
  echo "exit $?"
  if [ "${ZIG:-0}" = 1 ]; then
    echo "--- with a searchd (ReleaseSmall, head): test_example_loop"
    (cd "$DEST" && SEARCHD_BINARY="$V/rs-prefix/bin/searchd" python3 -I -m unittest discover -v -s tests -p test_example_loop.py 2>&1 | sed -e "s#$V#<vscratch>#g" -e "s#$HOME#<home>#g"; exit ${PIPESTATUS[0]})
    echo "exit $?"
  fi
} > "$OUT" 2>&1
grep -E "^(planted|exit|FAIL:|ERROR:|AssertionError|OK|FAILED)" "$OUT"
