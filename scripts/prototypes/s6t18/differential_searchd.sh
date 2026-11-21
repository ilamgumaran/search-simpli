#!/bin/bash
# S6-T18 ruling 1: a stand-in `searchd` for the Python suite (SEARCHD_BINARY=this file). For `query`,
# `evidence` and `search` it runs SEARCHD_MAIN and SEARCHD_HEAD with the same arguments (stdin closed), compares
# their stdout, stderr and exit status byte for byte, logs one line to DIFF_LOG, and answers with the head's.
# Any other command is the head's (exec). DIFF_TMP: a folder for the captured outputs (kept).
set -u
case "${1:-}" in
  query|evidence|search)
    tmp="$(mktemp -d "$DIFF_TMP/c.XXXXXX")"
    "$SEARCHD_MAIN" "$@" > "$tmp/main.out" 2> "$tmp/main.err" < /dev/null
    m=$?
    "$SEARCHD_HEAD" "$@" > "$tmp/head.out" 2> "$tmp/head.err" < /dev/null
    h=$?
    if [ "$m" = "$h" ] && cmp -s "$tmp/main.out" "$tmp/head.out" && cmp -s "$tmp/main.err" "$tmp/head.err"; then
      echo "same $1 exit=$h out=$(wc -c < "$tmp/head.out" | tr -d ' ') $tmp" >> "$DIFF_LOG"
    else
      echo "DIFFER $1 exit=$m/$h $tmp" >> "$DIFF_LOG"
    fi
    cat "$tmp/head.out"
    cat "$tmp/head.err" >&2
    exit "$h"
    ;;
  *)
    exec "$SEARCHD_HEAD" "$@"
    ;;
esac
