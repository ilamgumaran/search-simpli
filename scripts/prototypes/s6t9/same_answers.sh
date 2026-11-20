#!/bin/bash
# S6-T9 ruling 3: same answers as main for one corpus, through the C ABI
# (scripts/prototypes/s6t7/same_answers.py) and through searchd's surfaces
# (scripts/prototypes/s6t7/surfaces.py), both unchanged.
#   same_answers.sh KIND CORPUS MAIN_LIB HEAD_LIB MAIN_SEARCHD HEAD_SEARCHD MAIN_INDEX HEAD_INDEX FOLDER QUERIES WORK
# KIND is abi or surfaces. FOLDER is the indexed folder, or `apply:CHANGES`
# for J2 (no folder: `searchd search` is skipped by surfaces.py when FOLDER
# is `-`). WORK must not exist. Three comparisons:
#   fresh    main on MAIN_INDEX, the branch on HEAD_INDEX (each its own);
#   old      main on MAIN_INDEX, the branch on MAIN_INDEX (main's format);
#   updated  MAIN_INDEX updated once by each side (index --update, the
#            folder unchanged; J2: apply of one added file), each read by
#            its own library: the branch's is its first publish.
# Prints one line per comparison; exits 1 on any difference.
set -u
kind="$1"; corpus="$2"; main_lib="$3"; head_lib="$4"; main_sd="$5"; head_sd="$6"
main_index="$7"; head_index="$8"; folder="$9"; queries="${10}"; work="${11}"
here="$(cd "$(dirname "$0")" && pwd)"
[ -e "$work" ] && { echo "$work exists"; exit 3; }
mkdir -p "$work"
cp -R "$main_index" "$work/old"
cp -R "$main_index" "$work/upd-main"
cp -R "$main_index" "$work/upd-head"
added='{"changes":[{"op":"add","root_id":"r-legacy","path":"zz-added.txt","content_base64":"QSBuZXcgbm90ZSBhYm91dCB0aGUgZ2FyZGVuIHNoZWQuCg=="}]}'
if [ "${folder#apply:}" != "$folder" ]; then
  # J2's roots are school, home and laptop.
  printf '%s' "${added/r-legacy/home}" > "$work/added.json"
  "$main_sd" apply "$work/upd-main" --changes "$work/added.json" > /dev/null || exit 2
  "$head_sd" apply "$work/upd-head" --changes "$work/added.json" > /dev/null || exit 2
  dir="-"
else
  "$main_sd" index "$folder" --out "$work/upd-main" --update --filename-index > /dev/null || exit 2
  "$head_sd" index "$folder" --out "$work/upd-head" --update --filename-index > /dev/null || exit 2
  dir="$folder"
fi
status=0
answer() { # side lib searchd index out
  if [ "$kind" = abi ]; then
    python3 -I "$here/../s6t7/same_answers.py" answers "$2" "$4" "$queries" "$5" > /dev/null || exit 2
  else
    python3 -I "$here/../s6t7/surfaces.py" answers "$3" "$4" "$dir" "$queries" "$5" > /dev/null || exit 2
  fi
}
answer main "$main_lib" "$main_sd" "$main_index" "$work/main-fresh.jsonl"
answer head "$head_lib" "$head_sd" "$head_index" "$work/head-fresh.jsonl"
answer head "$head_lib" "$head_sd" "$work/old" "$work/head-old.jsonl"
answer main "$main_lib" "$main_sd" "$work/upd-main" "$work/main-upd.jsonl"
answer head "$head_lib" "$head_sd" "$work/upd-head" "$work/head-upd.jsonl"
compare() {
  if [ "$kind" = abi ]; then script="$here/../s6t7/same_answers.py"; else script="$here/../s6t7/surfaces.py"; fi
  line=$(python3 -I "$script" compare "$2" "$3") || status=1
  echo "$1 $corpus: $line"
}
compare fresh "$work/main-fresh.jsonl" "$work/head-fresh.jsonl"
compare old "$work/main-fresh.jsonl" "$work/head-old.jsonl"
compare updated "$work/main-upd.jsonl" "$work/head-upd.jsonl"
exit $status
