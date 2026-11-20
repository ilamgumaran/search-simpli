#!/bin/bash
# S6-T13 verifier: one cross-process run. vxrun.sh KEEP SECONDS SCRATCH: a fresh index directory seeded with
# generation 1, then the writer (head's library) and two readers (main's and head's libraries) at once.
set -u
keep=$1; secs=$2; V=$3; here="$(cd "$(dirname "$0")" && pwd)"
D=$V/xproc.noindex/keep-$keep-${VXDOCS:-240}; mkdir -p $D
python3 -I $here/vxproc.py writer $V/libs/head/libsearch_simpli.dylib $D 0 $keep 1 > /dev/null
python3 -I $here/vxproc.py writer $V/libs/head/libsearch_simpli.dylib $D $secs $keep 2 &
python3 -I $here/vxproc.py reader $V/libs/main/libsearch_simpli.dylib $D $secs main &
python3 -I $here/vxproc.py reader $V/libs/head/libsearch_simpli.dylib $D $secs head &
wait
